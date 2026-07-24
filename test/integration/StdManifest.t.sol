// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CentrifugeIntegrationTestWithUtils} from "./Integration.t.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IHubRegistry} from "../../src/core/hub/interfaces/IHubRegistry.sol";
import {IManagerCallFromHub} from "../../src/core/utils/interfaces/IManagerCall.sol";

import {MAX_MESSAGE_COST as GAS} from "../../src/admin/interfaces/IGasService.sol";

import {INAVManager} from "../../src/hooks/accounting/interfaces/INAVManager.sol";

import {SupervisorFactory} from "../../src/managers/hub/Supervisor.sol";
import {ISupervisor, TrustedCall} from "../../src/managers/hub/interfaces/ISupervisor.sol";

import {ManagerAction} from "../../src/vaults/interfaces/IBatchRequestManager.sol";

import {IStdManifest} from "../../src/manifests/interfaces/IStdManifest.sol";
import {StdManifest, StdManifestFactory} from "../../src/manifests/StdManifest.sol";

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

    StdManifestFactory manifestFactory;
    StdManifest manifest;
    ISupervisor supervisor;

    function setUp() public override {
        super.setUp();
        _createPool();

        // Deploy the pool's Supervisor (sentinel registry) and StdManifest.
        supervisor = new SupervisorFactory(IHub(address(hub))).newSupervisor(POOL_A, mockUpdater);
        manifestFactory = new StdManifestFactory(IHub(address(hub)), multiAdapter, shareClassManager);
        manifest = StdManifest(
            address(
                manifestFactory.newStdManifest(
                    IStdManifest.Config({
                        delay: POLICY_DELAY,
                        expiry: POLICY_EXPIRY,
                        escalation: POLICY_ESCALATION,
                        maxAbsolutePriceDelta: 0,
                        thresholdPerSecond: 0,
                        maxBrmPriceDeviation: type(uint128).max,
                        onchainAccounting: false,
                        navManager: address(0),
                        simplePriceManager: address(0),
                        requestManager: address(batchRequestManager),
                        bridgingHook: address(0),
                        oracleValuation: address(0),
                        contractUpdaterForwarder: address(contractUpdaterForwarder),
                        allowlist: new IStdManifest.Entry[](0)
                    })
                )
            )
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
        hub.initiateAuthorization(POOL_A, _grantManagerCall());

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
        hub.initiateAuthorization(POOL_A, _grantManagerCall());

        vm.prank(sentinel);
        supervisor.cancelAuthorization(_grantManagerCall());

        // Vetoed: even after the delay the call reverts.
        skip(POLICY_DELAY);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
    }

    function testReplacingManifestUsesEscalation() public {
        StdManifest next = StdManifest(
            address(
                new StdManifestFactory(IHub(address(hub)), multiAdapter, shareClassManager)
                    .newStdManifest(
                        IStdManifest.Config({
                            delay: POLICY_DELAY,
                            expiry: POLICY_EXPIRY,
                            escalation: POLICY_ESCALATION,
                            maxAbsolutePriceDelta: 0,
                            thresholdPerSecond: 0,
                            maxBrmPriceDeviation: type(uint128).max,
                            onchainAccounting: false,
                            navManager: address(0),
                            simplePriceManager: address(0),
                            requestManager: address(batchRequestManager),
                            bridgingHook: address(0),
                            oracleValuation: address(0),
                            contractUpdaterForwarder: address(contractUpdaterForwarder),
                            allowlist: new IStdManifest.Entry[](0)
                        })
                    )
            )
        );
        bytes memory call = abi.encodeCall(IHub.setManifest, (POOL_A, next));

        // A manager replacing the manifest is out of policy and waits the longer escalation delay.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, call);

        skip(POLICY_DELAY); // past the standard delay but not escalation
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.setManifest(POOL_A, next);

        skip(POLICY_ESCALATION - POLICY_DELAY);
        vm.prank(FM);
        hub.setManifest(POOL_A, next);
        assertEq(address(hub.manifest(POOL_A)), address(next));
    }

    /// @notice A manifest swap orphans authorizations the OLD manifest had pending: `consumeAuthorization`
    ///         checks the caller against whichever manifest is CURRENTLY installed, and the authId embeds
    ///         the manifest's own address, so neither the old nor the new manifest can finalize the old
    ///         one's pending call after the swap.
    function testManifestSwapOrphansPendingAuthorization() public {
        // Authorize a call under the original manifest, but don't let it mature yet.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, _grantManagerCall());

        StdManifest next = StdManifest(
            address(
                new StdManifestFactory(IHub(address(hub)), multiAdapter, shareClassManager)
                    .newStdManifest(
                        IStdManifest.Config({
                            delay: POLICY_DELAY,
                            expiry: POLICY_EXPIRY,
                            escalation: POLICY_ESCALATION,
                            maxAbsolutePriceDelta: 0,
                            thresholdPerSecond: 0,
                            maxBrmPriceDeviation: type(uint128).max,
                            onchainAccounting: false,
                            navManager: address(0),
                            simplePriceManager: address(0),
                            requestManager: address(batchRequestManager),
                            bridgingHook: address(0),
                            oracleValuation: address(0),
                            contractUpdaterForwarder: address(contractUpdaterForwarder),
                            allowlist: new IStdManifest.Entry[](0)
                        })
                    )
            )
        );

        // Swap the manifest via the ward break-glass path (skips needing a second authorization cycle).
        vm.prank(address(root));
        hub.setManifest(POOL_A, next);
        assertEq(address(hub.manifest(POOL_A)), address(next));

        // The original authorization's delay has now elapsed, but it can never be consumed: HubRegistry
        // checks msg.sender against the manifest CURRENTLY installed (`next`), not the one (`manifest`)
        // that created the authId.
        skip(POLICY_DELAY);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
        assertFalse(hubRegistry.manager(POOL_A, newManager));
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
        hub.initiateAuthorization(POOL_A, call);
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

    /// @dev BRM issue inner payload carrying `pricePoolPerShare` for SC_1.
    function _brmIssueInner(uint128 price) internal view returns (bytes memory) {
        return abi.encode(
            uint8(ManagerAction.IssueShares),
            ShareClassId.unwrap(SC_1),
            uint128(0),
            uint32(0),
            price,
            uint128(0),
            address(0)
        );
    }

    /// @notice A BRM issue within `maxBrmPriceDeviation` is in policy; one beyond is out-of-policy and requires
    ///         the standard authorize -> delay -> consume flow. Reads the real ShareClassManager price.
    ///
    /// @dev The matured path consumes at the manifest seam (`enforce`) rather than through a full
    ///      `hub.managerCall`: the BRM `IssueShares` body needs live epoch/approval state and would revert
    ///      inside the BRM, which is orthogonal to the price guard.
    function testBrmManagerCallPriceDeviationGuard() public {
        // Commit a main share price (setUp manifest has share-price guard disabled, so this runs synchronously).
        vm.prank(FM);
        hub.updateSharePrice(POOL_A, SC_1, D18.wrap(1e18), uint64(block.timestamp));
        (D18 mainPrice,) = shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        assertEq(mainPrice.raw(), 1e18, "main share price committed");

        // Install a manifest with a 1% price-deviation bound (Anemoy-style).
        StdManifest guarded = StdManifest(
            address(
                manifestFactory.newStdManifest(
                    IStdManifest.Config({
                        delay: POLICY_DELAY,
                        expiry: POLICY_EXPIRY,
                        escalation: POLICY_ESCALATION,
                        maxAbsolutePriceDelta: 0,
                        thresholdPerSecond: 0,
                        maxBrmPriceDeviation: 1e16,
                        onchainAccounting: false,
                        navManager: address(0),
                        simplePriceManager: address(0),
                        requestManager: address(batchRequestManager),
                        bridgingHook: address(0),
                        oracleValuation: address(0),
                        contractUpdaterForwarder: address(contractUpdaterForwarder),
                        allowlist: new IStdManifest.Entry[](0)
                    })
                )
            )
        );
        vm.prank(address(root));
        hub.setManifest(POOL_A, guarded);

        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 target = address(batchRequestManager).toBytes32();

        // In-bound issue (within 1%): in policy. `enforce` runs synchronously, consumes no authorization.
        bytes memory okCall =
            abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, _brmIssueInner(1e18 + 5e15), 0, 0, address(0)));
        assertEq(guarded.classify(POOL_A, FM, okCall), 0, "in-bound issue is in policy");
        vm.prank(address(hub));
        guarded.enforce(POOL_A, FM, okCall);

        // Over-deviating issue (>1%): out of policy.
        bytes memory badInner = _brmIssueInner(1e18 + 2e16);
        bytes memory badCall = abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, badInner, 0, 0, address(0)));
        assertEq(guarded.classify(POOL_A, FM, badCall), POLICY_DELAY, "over-deviating issue is out of policy");

        // Without an authorization the live managerCall reverts at the manifest gate, before the BRM body.
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, badInner, 0, 0, address(0));

        // Operator authorizes the exact calldata on the real ledger; not matured yet -> still reverts.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, badCall);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, badInner, 0, 0, address(0));

        // After the delay the matured authorization is consumed at the manifest seam.
        skip(POLICY_DELAY);
        vm.prank(address(hub));
        guarded.enforce(POOL_A, FM, badCall);
        assertEq(hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, badCall)), 0, "authorization consumed");
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
        hub.initiateAuthorization(POOL_A, call);
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
        hub.initiateAuthorization(POOL_A, call);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));

        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));
        assertTrue(oracleValuation.feeder(POOL_A, 0, priceFeeder), "feeder added via authorized managerCall");
    }

    /// @notice A non-withdrawal contract update is classified out of policy by `_checkManagerCall`: spoke
    ///         config actions are timelocked + sentinel-vetoable for manifest pools. The update now rides
    ///         the unified `managerCall` transport (sentinel target + wrapped payload).
    function testUpdateContractIsOutOfPolicyByDefault() public {
        _registerUSDC();

        uint16 localId = messageDispatcher.localCentrifugeId();

        // The spoke-side share token must exist for SyncManager.setMaxReserve. The notify calls are
        // in policy, so they run synchronously despite the installed manifest.
        vm.deal(FM, 1 ether);
        vm.startPrank(FM);
        hub.notifyPool{value: GAS}(POOL_A, localId, FUNDED);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, bytes32(bytes20(address(shareTokenRegistrar))), FUNDED);
        vm.stopPrank();

        uint128 newMaxReserve = 123e6;
        bytes32 target = address(syncManager).toBytes32();
        bytes memory payload = _syncManagerMaxReserveMsg(SC_1, usdcId, newMaxReserve);
        bytes memory call = abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, payload, 0, 0, address(0)));

        // Out of policy: without an authorization the call reverts (deny-by-default).
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));

        // Operator pre-authorizes the exact calldata; not matured yet -> still reverts.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, call);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));

        // After the delay it runs, reaching the migrated spoke target (SyncManager) directly via the Envoy.
        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.managerCall(POOL_A, localId, target, payload, 0, 0, address(0));
        assertEq(
            syncManager.maxReserve(POOL_A, SC_1, address(usdc), 0),
            newMaxReserve,
            "maxReserve set via authorized contract update"
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
