// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CentrifugeIntegrationTestWithUtils} from "./Integration.t.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IRegistrar} from "../../src/core/spoke/interfaces/IRegistrar.sol";
import {IHubRegistry} from "../../src/core/hub/interfaces/IHubRegistry.sol";
import {IManagerCallFromHub} from "../../src/core/utils/interfaces/IManagerCall.sol";

import {INAVManager} from "../../src/hooks/accounting/interfaces/INAVManager.sol";

import {SupervisorFactory} from "../../src/managers/hub/Supervisor.sol";
import {ISupervisor, TrustedCall} from "../../src/managers/hub/interfaces/ISupervisor.sol";

import {ManagerAction} from "../../src/vaults/interfaces/IBatchRequestManager.sol";

import {MAX_MESSAGE_COST as GAS} from "../utils/GasConstants.sol";
import {IStdHubPolicy} from "../../src/policies/hub/interfaces/IStdHubPolicy.sol";
import {StdHubPolicy, StdHubPolicyFactory} from "../../src/policies/hub/StdHubPolicy.sol";

/// @notice End-to-end test of the policy circuit breaker on a full single-chain deployment:
///         a pool with a real StdHubPolicy installed and a Supervisor wired as a hub manager,
///         exercising the in-policy / out-of-policy / authorize / sentinel-veto flows.
contract StdHubPolicyIntegrationTest is CentrifugeIntegrationTestWithUtils {
    using CastLib for address;

    uint48 constant POLICY_DELAY = 1 days;
    uint48 constant POLICY_EXPIRY = 7 days;
    uint48 constant POLICY_ESCALATION = 7 days;
    uint128 constant POLICY_PRICE_CAP = 5e17; // absolute per-update
    uint128 constant POLICY_PRICE_RATE = 1e15; // per second

    // `IHub.updateSharePrice` is overloaded; this is the no-timestamp one, whose calldata (and so authId)
    // is stable across the authorization delay.
    bytes4 constant UPDATE_SHARE_PRICE = bytes4(keccak256("updateSharePrice(uint64,bytes16,uint128)"));

    address immutable operator = makeAddr("operator");
    address immutable mockUpdater = makeAddr("mockUpdater");
    address immutable sentinel = makeAddr("sentinel");
    address immutable newManager = makeAddr("newManager");

    StdHubPolicyFactory policyFactory;
    StdHubPolicy policy;
    ISupervisor supervisor;

    function setUp() public override {
        super.setUp();
        _createPool();

        // Deploy the pool's Supervisor (sentinel registry) and StdHubPolicy.
        supervisor = new SupervisorFactory(IHub(address(hub))).newSupervisor(POOL_A, mockUpdater);
        policyFactory = new StdHubPolicyFactory(IHub(address(hub)), multiAdapter, shareClassManager);
        policy = StdHubPolicy(
            address(
                policyFactory.newHubPolicy(
                    IStdHubPolicy.Config({
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
                        allowlist: new IStdHubPolicy.Entry[](0)
                    })
                )
            )
        );

        // Register the operator and the Supervisor as hub managers BEFORE installing the policy
        // (no policy yet, so these grants are unguarded). The operator authorizes out-of-policy
        // calls on the HubRegistry ledger; the Supervisor must be a manager so it can reach the
        // registry's cancelAuthorization on behalf of sentinels.
        vm.startPrank(FM);
        hub.updateHubManager(POOL_A, operator, true);
        hub.updateHubManager(POOL_A, address(supervisor), true);
        vm.stopPrank();

        // Install the policy via the ward (Root) break-glass path.
        vm.prank(address(root));
        hub.setPolicy(POOL_A, policy);
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

    // ─── cancelAuthorization confinement ───────────────────────────────────────

    function _policyWith(IStdHubPolicy.Entry[] memory allowlist) internal returns (StdHubPolicy) {
        return StdHubPolicy(
            address(
                policyFactory.newHubPolicy(
                    IStdHubPolicy.Config({
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
                        allowlist: allowlist
                    })
                )
            )
        );
    }

    function _confine(address caller, bytes4 selector) internal view returns (IStdHubPolicy.Entry[] memory allowlist) {
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        allowlist = new IStdHubPolicy.Entry[](1);
        allowlist[0] = IStdHubPolicy.Entry({poolId: POOL_A, caller: caller, selectors: selectors});
    }

    function testConfinedManagerCannotCancelArbitraryAuthorization() public {
        // Confine the operator to notifyPool only. cancelAuthorization now flows through the policy, so a
        // manager restricted to a narrow selector set can no longer wield it as a pool-wide governance-DoS.
        StdHubPolicy confined = _policyWith(_confine(operator, IHub.notifyPool.selector));
        vm.prank(address(root));
        hub.setPolicy(POOL_A, confined);

        vm.prank(operator);
        vm.expectRevert(IStdHubPolicy.CallerNotAllowed.selector);
        hub.cancelAuthorization(POOL_A, _grantManagerCall());
    }

    function testSentinelVetoSurvivesRestrictivePolicy() public {
        // A policy that confines some manager must NOT break the Supervisor veto: the Supervisor is never
        // placed in an allowlist, so it stays unrestricted and its cancelAuthorization runs instantly.
        StdHubPolicy confined = _policyWith(_confine(newManager, IHub.notifyPool.selector));
        vm.prank(address(root));
        hub.setPolicy(POOL_A, confined);

        vm.prank(mockUpdater);
        IManagerCallFromHub(address(supervisor)).fromHub(POOL_A, abi.encode(TrustedCall.AddSentinel, sentinel));

        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, _grantManagerCall());

        vm.prank(sentinel);
        supervisor.cancelAuthorization(_grantManagerCall());

        // Vetoed under the restrictive policy: even after the delay the call reverts.
        skip(POLICY_DELAY);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
    }

    function testUnrestrictedManagerCancelIsInstant() public {
        // The operator is unrestricted under the setUp policy, so it can cancel a pending authorization
        // instantly (delay 0), with no timelock of its own.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, _grantManagerCall());
        assertGt(hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, _grantManagerCall())), 0);

        vm.prank(operator);
        hub.cancelAuthorization(POOL_A, _grantManagerCall());
        assertEq(
            hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, _grantManagerCall())), 0, "authorization cleared"
        );
    }

    function testReplacingPolicyUsesEscalation() public {
        StdHubPolicy next = StdHubPolicy(
            address(
                new StdHubPolicyFactory(IHub(address(hub)), multiAdapter, shareClassManager)
                    .newHubPolicy(
                        IStdHubPolicy.Config({
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
                            allowlist: new IStdHubPolicy.Entry[](0)
                        })
                    )
            )
        );
        bytes memory call = abi.encodeCall(IHub.setPolicy, (POOL_A, next));

        // A manager replacing the policy is out of policy and waits the longer escalation delay.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, call);

        skip(POLICY_DELAY); // past the standard delay but not escalation
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.setPolicy(POOL_A, next);

        skip(POLICY_ESCALATION - POLICY_DELAY);
        vm.prank(FM);
        hub.setPolicy(POOL_A, next);
        assertEq(address(hub.policy(POOL_A)), address(next));
    }

    /// @notice A policy swap orphans authorizations the OLD policy had pending: `consumeAuthorization`
    ///         checks the caller against whichever policy is CURRENTLY installed, and the authId embeds
    ///         the policy's own address, so neither the old nor the new policy can finalize the old
    ///         one's pending call after the swap.
    function testPolicySwapOrphansPendingAuthorization() public {
        // Authorize a call under the original policy, but don't let it mature yet.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, _grantManagerCall());

        StdHubPolicy next = StdHubPolicy(
            address(
                new StdHubPolicyFactory(IHub(address(hub)), multiAdapter, shareClassManager)
                    .newHubPolicy(
                        IStdHubPolicy.Config({
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
                            allowlist: new IStdHubPolicy.Entry[](0)
                        })
                    )
            )
        );

        // Swap the policy via the ward break-glass path (skips needing a second authorization cycle).
        vm.prank(address(root));
        hub.setPolicy(POOL_A, next);
        assertEq(address(hub.policy(POOL_A)), address(next));

        // The original authorization's delay has now elapsed, but it can never be consumed: HubRegistry
        // checks msg.sender against the policy CURRENTLY installed (`next`), not the one (`policy`)
        // that created the authId.
        skip(POLICY_DELAY);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
        assertFalse(hubRegistry.manager(POOL_A, newManager));
    }

    /// @notice `managerCall` is in policy only when it targets the configured request manager (BRM). Any
    ///         other target (here a Supervisor) falls through to the deny-by-default branch
    ///         (`StdHubPolicy._authorizationDelay` returns `delay`): out-of-policy, timelocked + sentinel-vetoable, NOT
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
    ///         policy seam: `enforce` of a BRM-targeted call neither reverts nor consumes an authorization.
    function testBrmManagerCallIsInPolicy() public {
        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 target = address(batchRequestManager).toBytes32();
        // Opaque payload: target is pinned, so its contents are not inspected by the classifier.
        bytes memory payload = abi.encode(uint8(1), bytes16(0));
        bytes memory call = abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, payload, 0, 0, address(0)));

        // In policy: enforce succeeds with no prior authorize() (deny-by-default would revert Unauthorized).
        vm.prank(address(hub));
        policy.enforce(POOL_A, FM, call);
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
    /// @dev The matured path consumes at the policy seam (`enforce`) rather than through a full
    ///      `hub.managerCall`: the BRM `IssueShares` body needs live epoch/approval state and would revert
    ///      inside the BRM, which is orthogonal to the price guard.
    function testBrmManagerCallPriceDeviationGuard() public {
        // Commit a main share price (setUp policy has share-price guard disabled, so this runs synchronously).
        vm.prank(FM);
        hub.updateSharePrice(POOL_A, SC_1, D18.wrap(1e18), uint64(block.timestamp));
        (D18 mainPrice,) = shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        assertEq(mainPrice.raw(), 1e18, "main share price committed");

        // Install a policy with a 1% price-deviation bound (Anemoy-style).
        StdHubPolicy guarded = StdHubPolicy(
            address(
                policyFactory.newHubPolicy(
                    IStdHubPolicy.Config({
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
                        allowlist: new IStdHubPolicy.Entry[](0)
                    })
                )
            )
        );
        vm.prank(address(root));
        hub.setPolicy(POOL_A, guarded);

        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 target = address(batchRequestManager).toBytes32();

        // In-bound issue (within 1%): in policy. `enforce` runs synchronously, consumes no authorization.
        bytes memory okCall =
            abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, _brmIssueInner(1e18 + 5e15), 0, 0, address(0)));
        assertEq(guarded.authorizationDelay(POOL_A, FM, okCall), 0, "in-bound issue is in policy");
        vm.prank(address(hub));
        guarded.enforce(POOL_A, FM, okCall);

        // Over-deviating issue (>1%): out of policy.
        bytes memory badInner = _brmIssueInner(1e18 + 2e16);
        bytes memory badCall = abi.encodeCall(IHub.managerCall, (POOL_A, localId, target, badInner, 0, 0, address(0)));
        assertEq(guarded.authorizationDelay(POOL_A, FM, badCall), POLICY_DELAY, "over-deviating issue is out of policy");

        // Without an authorization the live managerCall reverts at the policy gate, before the BRM body.
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, badInner, 0, 0, address(0));

        // Operator authorizes the exact calldata on the real ledger; not matured yet -> still reverts.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, badCall);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.managerCall(POOL_A, localId, target, badInner, 0, 0, address(0));

        // After the delay the matured authorization is consumed at the policy seam.
        skip(POLICY_DELAY);
        vm.prank(address(hub));
        guarded.enforce(POOL_A, FM, badCall);
        assertEq(hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, badCall)), 0, "authorization consumed");
    }

    // ─── share-price guard ─────────────────────────────────────────────────────

    function _priceGuardedPolicy() internal returns (StdHubPolicy) {
        return StdHubPolicy(
            address(
                policyFactory.newHubPolicy(
                    IStdHubPolicy.Config({
                        delay: POLICY_DELAY,
                        expiry: POLICY_EXPIRY,
                        escalation: POLICY_ESCALATION,
                        maxAbsolutePriceDelta: POLICY_PRICE_CAP,
                        thresholdPerSecond: POLICY_PRICE_RATE,
                        maxBrmPriceDeviation: type(uint128).max,
                        onchainAccounting: false,
                        navManager: address(0),
                        simplePriceManager: address(0),
                        requestManager: address(batchRequestManager),
                        bridgingHook: address(0),
                        oracleValuation: address(0),
                        allowlist: new IStdHubPolicy.Entry[](0)
                    })
                )
            )
        );
    }

    /// @notice A share class's price slot starts fully uninitialized, so a first computed price of 0 is a
    ///         no-op against the stored price while still being a real commit. Against the live
    ///         ShareClassManager this asserts both halves of the invariant the mocked unit test cannot:
    ///         the Hub really wrote the zero price (`computedAt` moves off zero) AND the policy anchored
    ///         its baseline on it, so the recovery move off zero is guarded rather than inheriting the
    ///         unguarded first-update slot. Recovery is then the ordinary authorize -> mature -> execute path.
    function testZeroFirstSharePriceCommitsAndAnchorsBaseline() public {
        StdHubPolicy guarded = _priceGuardedPolicy();
        vm.prank(address(root));
        hub.setPolicy(POOL_A, guarded);

        // Nothing committed and no baseline: the price slot really is (0, 0).
        (D18 price, uint64 computedAt) = shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        assertEq(price.raw(), 0, "price slot uninitialized");
        assertEq(computedAt, 0, "computedAt slot uninitialized");
        assertEq(guarded.lastPriceUpdate(POOL_A, SC_1), 0, "no baseline yet");

        // The first update is in policy. Committing 0 leaves `price` untouched but moves `computedAt` off
        // zero, so the Hub did commit it, and the policy must anchor on it anyway.
        vm.prank(FM);
        hub.updateSharePrice(POOL_A, SC_1, D18.wrap(0));
        (price, computedAt) = shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        assertEq(price.raw(), 0, "zero price committed");
        assertEq(computedAt, block.timestamp, "committed price is live: computedAt != 0");
        assertEq(guarded.lastPriceUpdate(POOL_A, SC_1), block.timestamp, "baseline anchored on the no-op");

        // A day on, the move off zero is bounded by the absolute cap (delta 1e18 >= 5e17) rather than
        // waved through as the instance's first update.
        skip(1 days);
        bytes memory recovery = abi.encodeWithSelector(UPDATE_SHARE_PRICE, POOL_A, SC_1, D18.wrap(1e18));
        assertEq(guarded.authorizationDelay(POOL_A, FM, recovery), POLICY_DELAY, "recovery is out of policy");
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.updateSharePrice(POOL_A, SC_1, D18.wrap(1e18));

        // Authorized and matured, the same call goes through and re-anchors the baseline.
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, recovery);
        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.updateSharePrice(POOL_A, SC_1, D18.wrap(1e18));
        (price,) = shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        assertEq(price.raw(), 1e18, "recovered off zero");
        assertEq(guarded.lastPriceUpdate(POOL_A, SC_1), block.timestamp, "baseline re-anchored");
        assertEq(hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, recovery)), 0, "authorization consumed");
    }

    /// @notice A NAVManager admin action (`setNAVHook`) routed through `hub.managerCall` is out of policy
    ///         by default, so a policy pool timelocks + sentinel-vetoes it. This is the coverage that the
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
    ///         without the policy's timelock + sentinel veto.
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

    /// @dev `notifyPool` stays in policy, so it lands synchronously. Required before the share class:
    ///      {SpokeRegistry.addShareClass} reverts `InvalidPool` until the spoke knows the pool.
    function _notifyPool() internal {
        uint16 localId = messageDispatcher.localCentrifugeId();
        vm.deal(FM, 1 ether);
        vm.prank(FM);
        hub.notifyPool{value: GAS}(POOL_A, localId, FUNDED);
    }

    /// @dev Must stay byte-identical to the live `hub.notifyShareClass` call sites: the authorization pins the
    ///      whole calldata, down to `extraGasLimit` and `refund`.
    function _notifyShareClassCall(address registrar, bytes memory payload) internal view returns (bytes memory) {
        return abi.encodeCall(
            IHub.notifyShareClass,
            (POOL_A, SC_1, messageDispatcher.localCentrifugeId(), registrar.toBytes32(), payload, 0, FUNDED)
        );
    }

    /// @notice The one notification that does not re-push committed state: `registrar` is caller-supplied, and
    ///         {SpokeHandler.addShareClass} calls `newToken` on it and registers whatever it returns, handing
    ///         that address the share class's mint authority on the destination chain.
    function testNotifyShareClassIsOutOfPolicyByDefault() public {
        _notifyPool();

        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 registrarId = address(shareTokenRegistrar).toBytes32();
        bytes memory call = _notifyShareClassCall(address(shareTokenRegistrar), "");

        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, registrarId, "", 0, FUNDED);
        assertFalse(spokeRegistry.hasShareClass(POOL_A, SC_1), "nothing landed on the spoke");

        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, call);
        assertEq(
            hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, call)),
            block.timestamp + POLICY_DELAY,
            "flat delay, not escalation"
        );

        // Not matured yet -> still reverts.
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, registrarId, "", 0, FUNDED);

        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, registrarId, "", 0, FUNDED);

        assertTrue(spokeRegistry.hasShareClass(POOL_A, SC_1), "share class registered on the spoke");
        (, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(POOL_A, SC_1);
        assertEq(address(registrar), address(shareTokenRegistrar), "authorized registrar owns the share token");
        assertEq(hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, call)), 0, "authorization consumed");
    }

    /// @notice The property the classification buys: a sentinel reads the proposed registrar off
    ///         `AuthorizationScheduled` and cancels within the window. No Supervisor branch is needed, since
    ///         `_checkNotSelfRemoval` only inspects `managerCall`.
    function testSentinelCanVetoNotifyShareClass() public {
        _notifyPool();

        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 registrarId = address(shareTokenRegistrar).toBytes32();
        bytes memory call = _notifyShareClassCall(address(shareTokenRegistrar), "");

        vm.prank(mockUpdater);
        IManagerCallFromHub(address(supervisor)).fromHub(POOL_A, abi.encode(TrustedCall.AddSentinel, sentinel));

        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, call);
        assertGt(hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, call)), 0, "authorization pending");

        vm.prank(sentinel);
        supervisor.cancelAuthorization(call);
        assertEq(hubRegistry.authorizedAfter(hubRegistry.authId(POOL_A, call)), 0, "authorization vetoed");

        skip(POLICY_DELAY);
        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, registrarId, "", 0, FUNDED);
        assertFalse(spokeRegistry.hasShareClass(POOL_A, SC_1), "no registrar took the share class");
    }

    /// @notice The authorization hashes the whole calldata, so the registrar a sentinel blessed is the one that
    ///         executes: a manager cannot bank the canonical registrar and substitute another after maturity.
    function testNotifyShareClassAuthorizationPinsRegistrarAndPayload() public {
        _notifyPool();

        uint16 localId = messageDispatcher.localCentrifugeId();
        bytes32 canonical = address(shareTokenRegistrar).toBytes32();
        bytes32 hostile = makeAddr("hostileRegistrar").toBytes32();
        bytes memory call = _notifyShareClassCall(address(shareTokenRegistrar), "");

        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, call);
        skip(POLICY_DELAY);

        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, hostile, "", 0, FUNDED);

        vm.prank(FM);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, canonical, hex"01", 0, FUNDED);

        // The exact authorized calldata still executes, so the two reverts were the mismatch and nothing else.
        vm.prank(FM);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, canonical, "", 0, FUNDED);
        (, IRegistrar registrar) = spokeRegistry.shareTokenAndRegistrar(POOL_A, SC_1);
        assertEq(address(registrar), address(shareTokenRegistrar), "only the authorized registrar executes");
    }

    /// @notice A non-withdrawal contract update is classified out of policy by `_checkManagerCall`: spoke
    ///         config actions are timelocked + sentinel-vetoable for policy pools. The update now rides
    ///         the unified `managerCall` transport (sentinel target + wrapped payload).
    function testUpdateContractIsOutOfPolicyByDefault() public {
        _registerUSDC();

        uint16 localId = messageDispatcher.localCentrifugeId();

        // The spoke-side share token must exist for SyncManager.setMaxReserve. notifyPool is in policy;
        // notifyShareClass is not, so it needs its own authorize -> mature -> execute cycle first.
        _notifyPool();
        bytes memory notifyCall = _notifyShareClassCall(address(shareTokenRegistrar), "");
        vm.prank(operator);
        hub.initiateAuthorization(POOL_A, notifyCall);
        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.notifyShareClass{value: GAS}(POOL_A, SC_1, localId, address(shareTokenRegistrar).toBytes32(), "", 0, FUNDED);

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
