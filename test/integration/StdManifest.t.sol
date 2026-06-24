// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CentrifugeIntegrationTestWithUtils} from "./Integration.t.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../src/core/hub/interfaces/IHubRegistry.sol";
import {IManagerCallFromHub} from "../../src/core/utils/interfaces/IManagerCall.sol";

import {MAX_MESSAGE_COST as GAS} from "../../src/admin/interfaces/IGasService.sol";

import {SupervisorFactory} from "../../src/managers/hub/Supervisor.sol";
import {INAVManager} from "../../src/managers/hub/interfaces/INAVManager.sol";
import {ISupervisor, TrustedCall} from "../../src/managers/hub/interfaces/ISupervisor.sol";

import {StdManifest} from "../../src/manifests/StdManifest.sol";
import {IStdManifest} from "../../src/manifests/interfaces/IStdManifest.sol";

/// @notice End-to-end test of the manifest circuit breaker on a full single-chain deployment:
///         a pool with a real StdManifest installed and a Supervisor wired as a hub manager,
///         exercising the in-policy / out-of-policy / authorize / sentinel-veto flows.
contract StdManifestIntegrationTest is CentrifugeIntegrationTestWithUtils {
    using CastLib for address;

    uint48 constant POLICY_DELAY = 1 days;
    uint48 constant POLICY_EXPIRY = 7 days;
    uint48 constant POLICY_ESCALATION = 7 days;

    address immutable operator = makeAddr("operator");
    address immutable mockUpdater = makeAddr("mockUpdater");
    address immutable sentinel = makeAddr("sentinel");
    address immutable newManager = makeAddr("newManager");

    StdManifest manifest;
    ISupervisor supervisor;

    function setUp() public override {
        super.setUp();
        _createPool();

        // Deploy the pool's Supervisor (sentinel registry) and StdManifest.
        supervisor = new SupervisorFactory(IHub(address(hub))).newSupervisor(POOL_A, mockUpdater);
        manifest = new StdManifest(
            IHub(address(hub)),
            multiAdapter,
            shareClassManager,
            IStdManifest.Config({
                delay: POLICY_DELAY,
                expiry: POLICY_EXPIRY,
                escalation: POLICY_ESCALATION,
                maxPriceDelta: 0,
                thresholdPerSecond: 0,
                onchainAccounting: false,
                navManager: address(0),
                simplePriceManager: address(0),
                requestManager: address(batchRequestManager),
                allowlist: new IStdManifest.Entry[](0)
            })
        );

        // Register the operator and the Supervisor as hub managers BEFORE installing the manifest
        // (no manifest yet, so these grants are unguarded). The operator authorizes out-of-policy
        // calls on the HubRegistry ledger; the Supervisor must be a manager so it can reach the
        // registry's cancelAuthorization on behalf of sentinels.
        vm.startPrank(FM);
        hub.updateHubManager(POOL_A, operator, true);
        hub.updateHubManager(POOL_A, address(supervisor), true);
        vm.stopPrank();

        // Install the manifest via the ward (Root) break-glass path.
        vm.prank(address(root));
        hub.setManifest(POOL_A, manifest);
    }

    function _grantManagerCall() internal view returns (bytes memory) {
        return abi.encodeCall(IHub.updateHubManager, (POOL_A, newManager, true));
    }

    function testInPolicyRunsSynchronously() public {
        // setPoolMetadata is in policy: runs immediately, no authorization.
        vm.prank(FM);
        hub.setPoolMetadata(POOL_A, "metadata");
    }

    function testOutOfPolicyReverts() public {
        // Granting a hub manager is out of policy; without an authorization it reverts.
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
    }

    function testAuthorizeThenExecute() public {
        // Operator (a hub manager) pre-authorizes the exact call on the registry.
        vm.prank(operator);
        hubRegistry.authorize(POOL_A, _grantManagerCall());

        // Not matured yet -> still reverts.
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);

        // After the delay it executes (consuming the authorization).
        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.updateHubManager(POOL_A, newManager, true);
        assertTrue(hubRegistry.manager(POOL_A, newManager));
    }

    function testSentinelCanVeto() public {
        // Operator authorizes, sentinel (installed via the manager-call dispatcher) cancels during the window.
        vm.prank(mockUpdater);
        IManagerCallFromHub(address(supervisor)).fromHub(POOL_A, abi.encode(TrustedCall.AddSentinel, sentinel));

        vm.prank(operator);
        hubRegistry.authorize(POOL_A, _grantManagerCall());

        vm.prank(sentinel);
        supervisor.cancelAuthorization(_grantManagerCall());

        // Vetoed: even after the delay the call reverts.
        skip(POLICY_DELAY);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
    }

    function testReplacingManifestUsesEscalation() public {
        StdManifest next = new StdManifest(
            IHub(address(hub)),
            multiAdapter,
            shareClassManager,
            IStdManifest.Config({
                delay: POLICY_DELAY,
                expiry: POLICY_EXPIRY,
                escalation: POLICY_ESCALATION,
                maxPriceDelta: 0,
                thresholdPerSecond: 0,
                onchainAccounting: false,
                navManager: address(0),
                simplePriceManager: address(0),
                requestManager: address(batchRequestManager),
                allowlist: new IStdManifest.Entry[](0)
            })
        );
        bytes memory call = abi.encodeCall(IHub.setManifest, (POOL_A, next));

        // A manager replacing the manifest is out of policy and waits the longer escalation delay.
        vm.prank(operator);
        hubRegistry.authorize(POOL_A, call);

        skip(POLICY_DELAY); // past the standard delay but not escalation
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.setManifest(POOL_A, next);

        skip(POLICY_ESCALATION - POLICY_DELAY);
        vm.prank(FM);
        hub.setManifest(POOL_A, next);
        assertEq(address(hub.manifest(POOL_A)), address(next));
    }

    /// @notice `managerCall` is in policy only when it targets the configured request manager (BRM). Any
    ///         other target (here a Supervisor) falls through to the deny-by-default branch
    ///         (`StdManifest._classify` returns `delay`): out-of-policy, timelocked + sentinel-vetoable, NOT
    ///         synchronous. Pinning the target also defeats the ABI collision where another target's payload
    ///         shares a BRM action's leading kind byte.
    function testSupervisorManagerCallIsOutOfPolicyByDefault() public {
        // A second Supervisor bound to the REAL Envoy so a live `hub.managerCall` can reach
        // its `fromHub` (the test's `supervisor` above is bound to a mock updater). AddSentinel needs no
        // pool state, making it a clean managerCall target.
        ISupervisor target =
            ISupervisor(address(new SupervisorFactory(IHub(address(hub))).newSupervisor(POOL_A, address(envoy))));

        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 targetId = address(target).toBytes32();
        bytes memory action = abi.encode(TrustedCall.AddSentinel, sentinel);
        bytes memory call = abi.encodeCall(IHub.managerCall, (POOL_A, localId, targetId, action, 0, 0, address(0)));

        // Out of policy: without an authorization the managerCall reverts (deny-by-default).
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, targetId, action, 0, 0, address(0));

        // Operator pre-authorizes the exact calldata; not matured yet -> still reverts.
        vm.prank(operator);
        hubRegistry.authorize(POOL_A, call);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, targetId, action, 0, 0, address(0));

        // After the delay it runs synchronously, consuming the authorization.
        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.managerCall(POOL_A, localId, targetId, action, 0, 0, address(0));
        assertTrue(target.sentinels(sentinel), "sentinel added via authorized managerCall");
    }

    /// @notice `managerCall` targeting the configured request manager (BRM) is in policy: routine keeper ops
    ///         (approve/issue/revoke/forceCancel) run synchronously, no authorization needed. Verified at the
    ///         manifest seam: `enforce` of a BRM-targeted call neither reverts nor consumes an authorization.
    function testBrmManagerCallIsInPolicy() public {
        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 target = address(batchRequestManager).toBytes32();
        // Opaque payload: target is pinned, so its contents are not inspected by the classifier.
        bytes memory payload = abi.encode(uint8(1), bytes16(0));
        bytes memory call = abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, payload, 0, 0, address(0)));

        // In policy: enforce succeeds with no prior authorize() (deny-by-default would revert Unauthorized).
        vm.prank(address(hub));
        manifest.enforce(POOL_A, FM, call);
    }

    /// @notice A NAVManager admin action (`setNAVHook`) routed through `hub.managerCall` is out of policy
    ///         by default, so a manifest pool timelocks + sentinel-vetoes it. This is the coverage that the
    ///         NAVManager admin surface previously bypassed entirely
    function testNavManagerSetNavHookIsOutOfPolicyByDefault() public {
        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 target = address(navManager).toBytes32();
        address hook = makeAddr("navHook");
        bytes memory payload = abi.encode(uint8(INAVManager.ManagerCall.SetNavHook), hook);
        bytes memory call = abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, payload, 0, 0, address(0)));

        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));

        vm.prank(operator);
        hubRegistry.authorize(POOL_A, call);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));

        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));
        assertEq(address(navManager.navHook(POOL_A)), hook, "navHook set via authorized managerCall");
    }

    /// @notice OracleValuation feeder management (`updateFeeder`) routed through `hub.managerCall` is out of
    ///         policy by default, same as the NAVManager case: a malicious feeder can no longer be added
    ///         without the manifest's timelock + sentinel veto.
    function testOracleUpdateFeederIsOutOfPolicyByDefault() public {
        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 target = address(oracleValuation).toBytes32();
        bytes32 priceFeeder = makeAddr("priceFeeder").toBytes32();
        bytes memory payload = abi.encode(uint16(0), priceFeeder, true);
        bytes memory call = abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, payload, 0, 0, address(0)));

        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));

        vm.prank(operator);
        hubRegistry.authorize(POOL_A, call);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));

        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));
        assertTrue(oracleValuation.feeder(POOL_A, 0, priceFeeder), "feeder added via authorized managerCall");
    }

    /// @notice A non-withdrawal `updateContract` is classified out of policy by `_checkUpdateContract`:
    ///         spoke config actions are timelocked + sentinel-vetoable for manifest pools.
    function testUpdateContractIsOutOfPolicyByDefault() public {
        _registerUSDC();

        uint16 localId = messageDispatcher.localCentrifugeId();

        // The spoke-side share token must exist for SyncManager.setMaxReserve. The notify calls are
        // in policy, so they run synchronously despite the installed manifest.
        vm.deal(FM, 1 ether);
        vm.startPrank(FM);
        hub.notifyPool{value: GAS}(POOL_A, localId, FUNDED);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, bytes32(0), FUNDED);
        vm.stopPrank();

        uint128 newMaxReserve = 123e6;
        bytes32 target = address(syncManager).toBytes32();
        bytes memory inner = _updateContractSyncDepositMaxReserveMsg(usdcId, newMaxReserve);
        bytes memory call = abi.encodeCall(IHub.updateContract, (POOL_A, SC_1, localId, target, inner, 0, address(0)));

        // Out of policy: without an authorization the call reverts (deny-by-default).
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateContract(POOL_A, SC_1, localId, target, inner, 0, address(0));

        // Operator pre-authorizes the exact calldata; not matured yet -> still reverts.
        vm.prank(operator);
        hubRegistry.authorize(POOL_A, call);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateContract(POOL_A, SC_1, localId, target, inner, 0, address(0));

        // After the delay it runs, reaching the unchanged legacy spoke target via contractUpdater.
        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.updateContract(POOL_A, SC_1, localId, target, inner, 0, address(0));
        assertEq(
            syncManager.maxReserve(POOL_A, SC_1, address(usdc), 0),
            newMaxReserve,
            "maxReserve set via authorized updateContract"
        );
    }

    /// @notice R5 ward-graph guardrail. The two-method routing replaces the ERC165 probe, so the standing
    ///         invariant is now the ward chain that carries a hub managerCall up to the Envoy, plus the fact
    ///         that each managerCall target binds the Envoy by an immutable msg.sender check (not a ward).
    ///         If any link breaks, `managerCall` to the BRM/Supervisor stops working.
    function testManagerCallWardGraph() public {
        // manager -> Hub -> MessageDispatcher -> Envoy
        assertEq(IAuth(address(messageDispatcher)).wards(address(hub)), 1, "Hub must be warded on MessageDispatcher");
        assertEq(
            IAuth(address(envoy)).wards(address(messageDispatcher)), 1, "MessageDispatcher must be warded on Envoy"
        );

        // Envoy -> BatchRequestManager is an immutable msg.sender check, not a ward (matching the other
        // managerCall targets). A dispatcher swap would force a BRM redeploy, which is why the dispatcher is final.
        assertEq(batchRequestManager.envoy(), address(envoy), "BRM bound to Envoy by immutable ref");

        // The Supervisor is reached via the same immutable msg.sender check: it does not inherit Auth, so it
        // has no ward surface to grant. A real-dispatcher-bound Supervisor carries that immutable ref.
        ISupervisor bound = new SupervisorFactory(IHub(address(hub))).newSupervisor(POOL_A, address(envoy));
        assertEq(bound.envoy(), address(envoy), "immutable binding");
    }
}
