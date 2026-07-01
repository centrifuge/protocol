// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {D18} from "../../src/misc/types/D18.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {HubRegistry} from "../../src/core/hub/HubRegistry.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IManifest} from "../../src/core/hub/interfaces/IManifest.sol";
import {IHub, ManagerKind} from "../../src/core/hub/interfaces/IHub.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IHubRegistry} from "../../src/core/hub/interfaces/IHubRegistry.sol";
import {ContractUpdateLib} from "../../src/core/utils/ContractUpdateLib.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../src/core/hub/interfaces/IShareClassManager.sol";

import {IOnOffRamp} from "../../src/managers/spoke/interfaces/IOnOffRamp.sol";

import {ManagerAction} from "../../src/vaults/interfaces/IBatchRequestManager.sol";

import "forge-std/Test.sol";

import {IStdManifest} from "../../src/manifests/interfaces/IStdManifest.sol";
import {StdManifest, StdManifestFactory} from "../../src/manifests/StdManifest.sol";

contract StdManifestTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));

    uint48 constant DELAY = 1 days;
    uint48 constant EXPIRY = 7 days;
    uint48 constant ESCALATION = 7 days;
    uint128 constant RATE = 1e15; // per second
    uint128 constant CAP = 5e17; // absolute per-update

    IHub immutable hub = IHub(makeAddr("Hub"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    address immutable supervisor = makeAddr("supervisor");
    address immutable brm = makeAddr("BRM");
    address immutable contractUpdaterForwarder = makeAddr("contractUpdaterForwarder");
    address immutable manager = makeAddr("manager");
    address immutable outsider = makeAddr("outsider");
    address immutable who = makeAddr("who");

    // The authorization ledger lives in a real HubRegistry, which the manifest classifies for.
    StdManifest manifest;
    HubRegistry hubRegistry;
    StdManifestFactory factory;

    function setUp() public {
        hubRegistry = new HubRegistry(address(this));
        vm.mockCall(address(hub), abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        factory = new StdManifestFactory(hub, multiAdapter, scm);
        manifest = StdManifest(address(factory.newStdManifest(_config(CAP, RATE, false, address(0), address(0)))));

        // Register the pool (manager becomes a manager; outsider is not) and install the manifest.
        hubRegistry.registerPool(POOL_A, manager, AssetId.wrap(1));
        hubRegistry.setManifest(POOL_A, manifest);

        // Baseline on-chain price = 1.0 for the share-price tests.
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector, POOL_A, SC_A),
            abi.encode(D18.wrap(1e18), uint64(0))
        );
    }

    function _config(uint128 cap, uint128 rate, bool onchain, address nav, address price)
        internal
        view
        returns (IStdManifest.Config memory)
    {
        return _config(cap, rate, onchain, nav, price, type(uint128).max, new IStdManifest.Entry[](0));
    }

    function _config(
        uint128 cap,
        uint128 rate,
        bool onchain,
        address nav,
        address price,
        IStdManifest.Entry[] memory allowlist
    ) internal view returns (IStdManifest.Config memory) {
        return _config(cap, rate, onchain, nav, price, type(uint128).max, allowlist);
    }

    function _config(uint128 cap, uint128 rate, bool onchain, address nav, address price, uint128 maxDeviation)
        internal
        view
        returns (IStdManifest.Config memory)
    {
        return _config(cap, rate, onchain, nav, price, maxDeviation, new IStdManifest.Entry[](0));
    }

    function _config(
        uint128 cap,
        uint128 rate,
        bool onchain,
        address nav,
        address price,
        uint128 maxDeviation,
        IStdManifest.Entry[] memory allowlist
    ) internal view returns (IStdManifest.Config memory) {
        return IStdManifest.Config({
            delay: DELAY,
            expiry: EXPIRY,
            escalation: ESCALATION,
            maxAbsolutePriceDelta: cap,
            thresholdPerSecond: rate,
            maxBrmPriceDeviation: maxDeviation,
            onchainAccounting: onchain,
            navManager: nav,
            simplePriceManager: price,
            requestManager: brm,
            contractUpdaterForwarder: contractUpdaterForwarder,
            allowlist: allowlist
        });
    }

    function _authId(bytes memory d) internal view returns (bytes32) {
        return hubRegistry.authId(POOL_A, d);
    }

    /// @dev Authorize `data` as a manager and return the classified delay (validAfter - now).
    function _delayOf(bytes memory d) internal returns (uint48) {
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);
        return hubRegistry.authorizedAfter(_authId(d)) - uint48(block.timestamp);
    }

    function _setManifestCall(address m) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHub.setManifest.selector, POOL_A, m);
    }

    function _priceCall(uint128 raw) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHub.updateSharePrice.selector, POOL_A, SC_A, D18.wrap(raw), uint64(0));
    }

    // ─── authorize flow (out-of-policy driven by the setManifest selector) ───────

    function testAuthorizeStoresValidAfter() public {
        bytes memory d = _setManifestCall(address(this));
        vm.expectEmit();
        emit IHubRegistry.AuthorizationScheduled(POOL_A, manager, _authId(d), uint48(block.timestamp) + ESCALATION, d);
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), block.timestamp + ESCALATION);
    }

    function testAuthorizeNotManager() public {
        vm.expectRevert(IHubRegistry.NotManager.selector);
        vm.prank(outsider);
        hubRegistry.authorize(POOL_A, _setManifestCall(address(this)));
    }

    function testReauthorizePendingReverts() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        // Re-authorizing a pending auth reverts rather than silently resetting its maturity clock.
        vm.expectRevert(IHubRegistry.AlreadyAuthorized.selector);
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);
    }

    function testReauthorizeExpiredReverts() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        // Past maturity + expiry the auth is dead but enforce never cleared it, so re-authorizing
        // still reverts — it must be cancelled first.
        skip(ESCALATION + EXPIRY + 1);
        vm.expectRevert(IHubRegistry.AlreadyAuthorized.selector);
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);
    }

    function testCancelThenReauthorize() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        vm.prank(manager);
        hubRegistry.cancelAuthorization(POOL_A, d);

        // Once cancelled, the same call can be authorized again.
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), block.timestamp + ESCALATION);
    }

    function testAuthorizeInPolicyReverts() public {
        // An in-policy call has nothing to authorize; banking it would let a manager fire it later
        // once the same calldata drifts out of policy.
        bytes memory d = abi.encodeWithSelector(IHub.notifyPool.selector, POOL_A, uint16(1), address(0));
        vm.expectRevert(IHubRegistry.InPolicy.selector);
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);
    }

    function testCancelAuthorization() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        vm.expectEmit();
        emit IHubRegistry.AuthorizationCanceled(POOL_A, manager, _authId(d));
        vm.prank(manager);
        hubRegistry.cancelAuthorization(POOL_A, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), 0);
    }

    function testCancelNotManager() public {
        vm.expectRevert(IHubRegistry.NotManager.selector);
        vm.prank(outsider);
        hubRegistry.cancelAuthorization(POOL_A, _setManifestCall(address(this)));
    }

    function testCancelNoAuthorizationReverts() public {
        // Cancelling a call that was never authorized fails loud rather than emitting a no-op event.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(manager);
        hubRegistry.cancelAuthorization(POOL_A, _setManifestCall(address(this)));
    }

    function testEnforceNotHub() public {
        vm.expectRevert(IManifest.NotHub.selector);
        vm.prank(outsider);
        manifest.enforce(POOL_A, manager, _setManifestCall(address(this)));
    }

    function testEnforceInPolicyIsNoop() public {
        // Unknown selector -> in policy, no authorization required.
        bytes memory d = abi.encodeWithSelector(IHub.notifyPool.selector, POOL_A, uint16(1), address(0));
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
    }

    function testEnforceOutOfPolicyWithoutAuthReverts() public {
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _setManifestCall(address(this)));
    }

    function testEnforceOutOfPolicyNotMaturedReverts() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        skip(ESCALATION - 1);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
    }

    function testEnforceOutOfPolicyMaturedConsumes() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        skip(ESCALATION);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), 0);

        // Single-shot: a second out-of-policy call reverts.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
    }

    function testEnforceOutOfPolicyExpiredReverts() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        // Matured but the execution window has closed: fails closed, the auth is no longer valid.
        skip(ESCALATION + EXPIRY + 1);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
    }

    function testEnforceOutOfPolicyAtExpiryBoundaryConsumes() public {
        bytes memory d = _setManifestCall(address(this));
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, d);

        // The last instant of the window is still valid (inclusive upper bound).
        skip(ESCALATION + EXPIRY);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), 0);
    }

    function testAuthorizationMatchesExactCalldata() public {
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, _setManifestCall(address(0xA)));
        skip(ESCALATION);

        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _setManifestCall(address(0xB)));
    }

    // ─── policy rules ────────────────────────────────────────────────────────────

    function testGrantHubManagerNeedsAuthorization() public {
        assertEq(_delayOf(abi.encodeWithSelector(IHub.updateHubManager.selector, POOL_A, who, true)), DELAY);
    }

    function testRevokeHubManagerNeedsAuthorization() public {
        // Revoking a hub manager is out of policy too, so the Supervisor can't be removed instantly.
        assertEq(_delayOf(abi.encodeWithSelector(IHub.updateHubManager.selector, POOL_A, who, false)), DELAY);
    }

    function testSetManifestNeedsAuthorization() public {
        assertEq(_delayOf(_setManifestCall(address(this))), ESCALATION);
    }

    // ─── share-price guard ─────────────────────────────────────────────────────────

    function testFirstPriceUpdateInPolicyAndCommits() public {
        // No baseline yet -> in policy; enforce commits the baseline timestamp.
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18));
        assertEq(manifest.lastPriceUpdate(POOL_A, SC_A), block.timestamp);
    }

    function testSmallPriceUpdateInPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18)); // baseline
        skip(100);

        // Tiny move, well under rate and cap.
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18 + 1e10));
    }

    function testRateLimitedPriceUpdateNeedsAuthorization() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18)); // baseline at T0
        skip(1); // 1 second later

        // delta 2e15 over 1s exceeds RATE (1e15/s); below CAP. Out of policy.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18 + 2e15));
    }

    function testAbsoluteCapHoldsAfterLongWait() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18)); // baseline
        skip(1e9); // huge elapsed -> rate would pass

        // delta 1e18 >= CAP (5e17): a single jump this large is out of policy regardless of time.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(2e18));
    }

    function testAuthorizeDoesNotMoveBaseline() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18)); // baseline at T0
        uint64 t0 = manifest.lastPriceUpdate(POOL_A, SC_A);

        skip(50);
        // Authorizing an out-of-policy price jump must NOT advance the baseline.
        vm.prank(manager);
        hubRegistry.authorize(POOL_A, _priceCall(2e18));
        assertEq(manifest.lastPriceUpdate(POOL_A, SC_A), t0);
    }

    function testSameBlockPriceUpdateNeedsAuthorization() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18)); // baseline committed this block

        // A second update in the SAME block has zero elapsed time: out of policy even though the
        // move is tiny. This closes the chunk-many-sub-threshold-updates-in-one-tx bypass.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18 + 1e10));
    }

    function testPriceGuardDisabled() public {
        manifest = StdManifest(address(factory.newStdManifest(_config(0, 0, false, address(0), address(0)))));

        // Establish a baseline, then a huge same-block jump: with both guards off everything is in policy.
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(1e18));
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCall(100e18));
    }

    // ─── managerCall classification ───────────────────────────────────────────────

    function _managerCall(bytes32 target, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IHub.managerCall.selector, POOL_A, uint16(1), target, inner, uint128(0), uint256(0), address(0)
        );
    }

    function testManagerCallToRequestManagerInPolicy() public {
        // managerCall targeting the configured request manager (BRM) is in policy: routine keeper ops run
        // synchronously, no authorization needed. The opaque payload is not inspected (target is pinned).
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _managerCall(bytes32(bytes20(brm)), abi.encode(uint8(1), bytes16(0))));
    }

    function testManagerCallToOtherTargetDenyByDefault() public {
        // Any other target (Supervisor, NAVManager, OracleValuation, unknown) falls to deny-by-default:
        // out of policy, standard delay + sentinel veto. Pinning the target defeats the ABI collision where
        // a Supervisor RemoveSentinel (kind byte 1) is disguised as a BRM ApproveDeposits (also kind 1).
        assertEq(
            _delayOf(_managerCall(bytes32(bytes20(supervisor)), abi.encode(uint8(1), makeAddr("attacker")))), DELAY
        );
    }

    function testManagerCallUnknownTargetDenyByDefault() public {
        // An unpinned target (neither the contractUpdaterForwarder nor the BRM) is out of policy: deny-by-default.
        assertEq(_delayOf(_managerCall(bytes32(bytes20(makeAddr("unknown"))), bytes(""))), DELAY);
    }

    // ─── BRM price-deviation guard ─────────────────────────────────────────────────

    uint128 constant DEVIATION = 1e16; // 1%
    AssetId constant ASSET = AssetId.wrap(7);

    /// @dev A BRM issue/revoke inner payload carrying `pricePoolPerShare` at word 4 (offset 144).
    function _brmShareAction(ManagerAction kind, uint128 price) internal pure returns (bytes memory) {
        return abi.encode(uint8(kind), ShareClassId.unwrap(SC_A), uint128(0), uint32(0), price, uint128(0), address(0));
    }

    /// @dev A BRM approve deposits/redeems inner payload carrying `pricePoolPerAsset` at word 5 (offset 176).
    function _brmApproveAction(ManagerAction kind, uint128 price) internal pure returns (bytes memory) {
        return abi.encode(
            uint8(kind), ShareClassId.unwrap(SC_A), AssetId.unwrap(ASSET), uint32(0), uint128(0), price, address(0)
        );
    }

    /// @dev Classify a BRM-targeted managerCall through a manifest carrying `maxDev`.
    function _classifyBrm(uint128 maxDev, bytes memory inner) internal returns (uint48) {
        // Fresh factory per call: this helper classifies many throwaway manifests whose configs may
        // repeat, and a shared factory's deterministic CREATE2 address would collide on a repeat.
        IStdManifest m = new StdManifestFactory(hub, multiAdapter, scm)
            .newStdManifest(_config(CAP, RATE, false, address(0), address(0), maxDev));
        return m.classify(POOL_A, manager, _managerCall(bytes32(bytes20(brm)), inner));
    }

    function _mockAssetPrice(uint128 raw) internal {
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(IHub.pricePoolPerAsset.selector, POOL_A, SC_A, ASSET),
            abi.encode(D18.wrap(raw))
        );
    }

    function testBrmIssueWithinBoundInPolicy() public {
        // Main share price = 1e18 (setUp). A move under 1% is in policy.
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.IssueShares, 1e18 + 5e15)), 0);
    }

    function testBrmIssueBeyondBoundDelayed() public {
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.IssueShares, 1e18 + 2e16)), DELAY);
    }

    function testBrmRevokeWithinBoundInPolicy() public {
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.RevokeShares, 1e18 - 5e15)), 0);
    }

    function testBrmRevokeBeyondBoundDelayed() public {
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.RevokeShares, 1e18 - 2e16)), DELAY);
    }

    function testBrmApproveDepositsWithinBoundInPolicy() public {
        _mockAssetPrice(1e18);
        assertEq(_classifyBrm(DEVIATION, _brmApproveAction(ManagerAction.ApproveDeposits, 1e18 + 5e15)), 0);
    }

    function testBrmApproveDepositsBeyondBoundDelayed() public {
        _mockAssetPrice(1e18);
        assertEq(_classifyBrm(DEVIATION, _brmApproveAction(ManagerAction.ApproveDeposits, 1e18 + 2e16)), DELAY);
    }

    function testBrmApproveRedeemsWithinBoundInPolicy() public {
        _mockAssetPrice(1e18);
        assertEq(_classifyBrm(DEVIATION, _brmApproveAction(ManagerAction.ApproveRedeems, 1e18 - 5e15)), 0);
    }

    function testBrmApproveRedeemsBeyondBoundDelayed() public {
        _mockAssetPrice(1e18);
        assertEq(_classifyBrm(DEVIATION, _brmApproveAction(ManagerAction.ApproveRedeems, 1e18 + 2e16)), DELAY);
    }

    function testBrmExactMatchBoundDeRwa() public {
        // maxBrmPriceDeviation == 0: exact match is in policy, any nonzero delta is out (deRWA semantics).
        assertEq(_classifyBrm(0, _brmShareAction(ManagerAction.IssueShares, 1e18)), 0);
        assertEq(_classifyBrm(0, _brmShareAction(ManagerAction.IssueShares, 1e18 + 1)), DELAY);
    }

    function testBrmMainSharePriceZeroDelayed() public {
        // No committed share price (reference reads 0): fails closed — requires a timelock authorization.
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector, POOL_A, SC_A),
            abi.encode(D18.wrap(0), uint64(0))
        );
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.IssueShares, 5e18)), DELAY);
    }

    function testBrmMainSharePriceZeroRevokeDelayed() public {
        // Same guard applies to RevokeShares.
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector, POOL_A, SC_A),
            abi.encode(D18.wrap(0), uint64(0))
        );
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.RevokeShares, 5e18)), DELAY);
    }

    function testBrmMainAssetPriceZeroDelayed() public {
        // A zero asset price from the oracle also fails closed.
        vm.mockCall(
            address(hub),
            abi.encodeWithSelector(IHub.pricePoolPerAsset.selector, POOL_A, SC_A, ASSET),
            abi.encode(D18.wrap(0))
        );
        assertEq(_classifyBrm(DEVIATION, _brmApproveAction(ManagerAction.ApproveDeposits, 1e18)), DELAY);
    }

    function testBrmApproveAssetPriceRevertBubblesUp() public {
        // A reverting oracle bubbles up: a manager must not approve against a broken price source.
        IStdManifest m = factory.newStdManifest(_config(CAP, RATE, false, address(0), address(0), DEVIATION));
        vm.mockCallRevert(
            address(hub), abi.encodeWithSelector(IHub.pricePoolPerAsset.selector, POOL_A, SC_A, ASSET), "PriceNotSet"
        );
        bytes memory call = _managerCall(bytes32(bytes20(brm)), _brmApproveAction(ManagerAction.ApproveDeposits, 1e18));
        vm.expectRevert();
        m.classify(POOL_A, manager, call);
    }

    function testBrmGuardDisabledAnyPriceInPolicy() public {
        // maxBrmPriceDeviation == type(uint128).max disables the guard: any price is in policy.
        assertEq(_classifyBrm(type(uint128).max, _brmShareAction(ManagerAction.IssueShares, 100e18)), 0);
    }

    /// @dev A BRM force-cancel inner payload (no price field).
    function _brmForceCancel(ManagerAction kind) internal pure returns (bytes memory) {
        return abi.encode(uint8(kind), ShareClassId.unwrap(SC_A), bytes32(0), AssetId.unwrap(ASSET), address(0));
    }

    function testBrmForceCancelDepositNoPriceInPolicy() public {
        // Force-cancels carry no price field: in policy regardless of the bound.
        assertEq(_classifyBrm(DEVIATION, _brmForceCancel(ManagerAction.ForceCancelDepositRequest)), 0);
    }

    function testBrmForceCancelRedeemNoPriceInPolicy() public {
        assertEq(_classifyBrm(DEVIATION, _brmForceCancel(ManagerAction.ForceCancelRedeemRequest)), 0);
    }

    function testBrmMalformedShortPayloadDelayed() public {
        // A price-bearing kind whose payload is too short to hold the price word fails closed -> delay.
        bytes memory inner = abi.encode(uint8(ManagerAction.IssueShares), ShareClassId.unwrap(SC_A));
        assertEq(_classifyBrm(DEVIATION, inner), DELAY);
    }

    // ─── contract-update classification (managerCall to the forwarder) ────────────

    function _updateContractCall(bytes32 target, bytes memory inner) internal view returns (bytes memory) {
        // A contract update is a `managerCall` to the contractUpdaterForwarder, carrying the scId + real
        // target + inner payload wrapped via {ContractUpdateLib.wrap}. The manifest sees the forwarder as the
        // target and dispatches to `_classifyContractUpdate`.
        bytes memory payload = ContractUpdateLib.wrap(SC_A, address(bytes20(target)), inner);
        return abi.encodeWithSelector(
            IHub.managerCall.selector,
            POOL_A,
            uint16(1),
            bytes32(bytes20(contractUpdaterForwarder)),
            payload,
            uint128(0),
            uint256(0),
            address(0)
        );
    }

    function testUpdateContractDefaultDelayed() public {
        // Anything that isn't an OnOffRamp Withdraw (here: Onramp config) is out of policy.
        bytes memory inner = abi.encode(uint8(IOnOffRamp.TrustedCall.Onramp));
        assertEq(_delayOf(_updateContractCall(bytes32(bytes20(makeAddr("ramp"))), inner)), DELAY);
    }

    function testUpdateContractSentinelManagementDelayed() public {
        // Sentinel add/remove flows through updateContract targeting the Supervisor: delayed.
        bytes memory inner = abi.encode(uint8(1), makeAddr("attacker")); // RemoveSentinel
        assertEq(_delayOf(_updateContractCall(bytes32(bytes20(supervisor)), inner)), DELAY);
    }

    function testUpdateContractWithdrawDelayed() public {
        // No fast path: even an OnOffRamp Withdraw-tagged update is out of policy (timelocked + vetoable).
        // The tag-only shortcut was removed because it ignored the target (Sherlock #15).
        bytes memory inner = abi.encode(uint8(IOnOffRamp.TrustedCall.Withdraw));
        assertEq(_delayOf(_updateContractCall(bytes32(bytes20(makeAddr("ramp"))), inner)), DELAY);
    }

    function testUpdateContractLargeFirstWordIsDelayedNotReverting() public {
        // An inner payload whose first word exceeds 255 (e.g. a target whose payload starts with a
        // uint256/address) must NOT revert during classification; every contract update is timelocked.
        bytes memory inner = abi.encode(uint256(type(uint256).max));
        assertEq(_delayOf(_updateContractCall(bytes32(bytes20(makeAddr("target"))), inner)), DELAY);
    }

    // ─── request manager / adapters manager / share hook ──────────────────────────

    function testSetRequestManagerNeedsAuthorization() public {
        bytes memory d = abi.encodeWithSelector(
            IHub.setRequestManager.selector, POOL_A, uint16(1), address(0), bytes32(0), address(0)
        );
        assertEq(_delayOf(d), DELAY);
    }

    function testUpdateShareHookNeedsAuthorization() public {
        bytes memory d =
            abi.encodeWithSelector(IHub.updateShareHook.selector, POOL_A, SC_A, uint16(1), bytes32(0), address(0));
        assertEq(_delayOf(d), DELAY);
    }

    function testUpdateVaultNeedsAuthorization() public {
        // Every vault update (deploy/link/unlink) is timelocked.
        bytes memory d = abi.encodeWithSelector(IHub.updateVault.selector, POOL_A, SC_A, uint8(0));
        assertEq(_delayOf(d), DELAY);
    }

    function _managerCall(ManagerKind kind, bytes32 who_, bool canManage) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHub.updateManager.selector, POOL_A, uint16(1), kind, who_, canManage, address(0));
    }

    function testGrantAdaptersManagerNeedsAuthorization() public {
        assertEq(_delayOf(_managerCall(ManagerKind.Adapter, bytes32(bytes20(who)), true)), DELAY);
    }

    function testRevokeAdaptersManagerInPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _managerCall(ManagerKind.Adapter, bytes32(bytes20(who)), false));
    }

    // ─── balance-sheet manager classification ─────────────────────────────────────

    function testGrantBalanceSheetManagerNeedsAuthorization() public {
        assertEq(_delayOf(_managerCall(ManagerKind.BalanceSheet, bytes32(bytes20(who)), true)), DELAY);
    }

    function testRevokeBalanceSheetManagerInPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _managerCall(ManagerKind.BalanceSheet, bytes32(bytes20(who)), false));
    }

    // ─── setAdapters classification ───────────────────────────────────────────────

    function _setAdaptersCall(IAdapter[] memory local) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IHub.setAdapters.selector, POOL_A, uint16(1), local, new bytes32[](0), uint8(0), uint8(0), address(0)
        );
    }

    function testSetAdaptersMatchingGlobalOutOfPolicy() public {
        IAdapter adapter = IAdapter(makeAddr("adapter"));
        vm.mockCall(
            address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.activeSessionId.selector), abi.encode(uint16(1))
        );
        vm.mockCall(address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.quorum.selector), abi.encode(uint8(1)));
        vm.mockCall(address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.adapters.selector), abi.encode(adapter));

        IAdapter[] memory local = new IAdapter[](1);
        local[0] = adapter;
        // A valid set still needs authorization and a veto window.
        assertEq(_delayOf(_setAdaptersCall(local)), DELAY);
    }

    function testSetAdaptersMismatchReverts() public {
        IAdapter adapter = IAdapter(makeAddr("adapter"));
        vm.mockCall(
            address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.activeSessionId.selector), abi.encode(uint16(1))
        );
        vm.mockCall(address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.quorum.selector), abi.encode(uint8(1)));
        vm.mockCall(address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.adapters.selector), abi.encode(adapter));

        IAdapter[] memory local = new IAdapter[](1);
        local[0] = IAdapter(makeAddr("wrongAdapter"));
        vm.expectRevert(IStdManifest.AdapterMismatch.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _setAdaptersCall(local));
    }

    function testSetAdaptersSubsetOfGlobalOutOfPolicy() public {
        IAdapter lz = IAdapter(makeAddr("lz"));
        IAdapter axelar = IAdapter(makeAddr("axelar"));
        // Global set for this chain is [lz, axelar].
        vm.mockCall(
            address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.activeSessionId.selector), abi.encode(uint16(1))
        );
        vm.mockCall(address(multiAdapter), abi.encodeWithSelector(IMultiAdapter.quorum.selector), abi.encode(uint8(2)));
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.adapters.selector, uint16(1), PoolId.wrap(0), uint16(1), uint256(0)),
            abi.encode(lz)
        );
        vm.mockCall(
            address(multiAdapter),
            abi.encodeWithSelector(IMultiAdapter.adapters.selector, uint16(1), PoolId.wrap(0), uint16(1), uint256(1)),
            abi.encode(axelar)
        );

        // Using only a subset (just axelar) of the global set is valid, but out of policy: it
        // weakens the threshold and so needs authorization and a veto window.
        IAdapter[] memory local = new IAdapter[](1);
        local[0] = axelar;
        assertEq(_delayOf(_setAdaptersCall(local)), DELAY);
    }

    // ─── deny-by-default ──────────────────────────────────────────────────────────

    function testUnknownSelectorOutOfPolicy() public {
        // A selector the manifest doesn't classify (e.g. a Hub method added later) falls through to
        // the deny-by-default branch: out of policy, so it can't run unguarded.
        bytes memory d = abi.encodeWithSelector(bytes4(0xdeadbeef), POOL_A);
        assertEq(_delayOf(d), DELAY);
    }

    // ─── on-chain accounting ──────────────────────────────────────────────────────

    address constant NAV = address(0xA1);
    address constant PRICE = address(0xB2);

    function _onchainManifest() internal returns (StdManifest) {
        return StdManifest(address(factory.newStdManifest(_config(CAP, RATE, true, NAV, PRICE))));
    }

    function testOnchainAccountingNavManagerInPolicy() public {
        StdManifest m = _onchainManifest();
        // The NAVManager drives accounting synchronously (in policy, no revert).
        vm.prank(address(hub));
        m.enforce(POOL_A, NAV, abi.encodeWithSelector(IHub.updateJournal.selector, POOL_A));
    }

    function testOnchainAccountingBlocksOtherCallers() public {
        StdManifest m = _onchainManifest();
        // Any other caller is blocked outright — can't touch accounting, can't even authorize it.
        vm.prank(address(hub));
        vm.expectRevert(IStdManifest.OnchainAccountingOnly.selector);
        m.enforce(POOL_A, manager, abi.encodeWithSelector(IHub.updateJournal.selector, POOL_A));
    }

    function testOnchainAccountingSharePriceOnlyFromPriceManager() public {
        StdManifest m = _onchainManifest();
        // Share price comes only from the SimplePriceManager.
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(2e18));

        vm.prank(address(hub));
        vm.expectRevert(IStdManifest.OnchainAccountingOnly.selector);
        m.enforce(POOL_A, manager, _priceCall(2e18));
    }

    function testOnchainAccountingSnapshotHookMustBeNavManager() public {
        StdManifest m = _onchainManifest();
        // The snapshot hook may only point at the NAVManager.
        vm.prank(address(hub));
        m.enforce(POOL_A, manager, abi.encodeWithSelector(IHub.setSnapshotHook.selector, POOL_A, NAV));

        vm.prank(address(hub));
        vm.expectRevert(IStdManifest.OnchainAccountingOnly.selector);
        m.enforce(POOL_A, manager, abi.encodeWithSelector(IHub.setSnapshotHook.selector, POOL_A, address(0xBAD)));
    }

    function testAccountingSelectorTimelockedWhenFlagOff() public {
        // With on-chain accounting off, manual accounting is out of policy (timelocked), not instant.
        assertEq(_delayOf(abi.encodeWithSelector(IHub.updateJournal.selector, POOL_A)), DELAY);
        assertEq(_delayOf(abi.encodeWithSelector(IHub.createAccount.selector, POOL_A)), DELAY);
    }

    // ─── addShareClass ────────────────────────────────────────────────────────────

    function testAddShareClassTimelocked() public {
        bytes memory d = abi.encodeWithSelector(IHub.addShareClass.selector, POOL_A, "n", "s", bytes32(0));
        assertEq(_delayOf(d), DELAY);
    }

    // ─── per-caller selector allowlist ─────────────────────────────────────────────

    address constant KEEPER = address(0xC3);

    /// @dev Manifest confining KEEPER to the given selectors; KEEPER is also a registered manager.
    function _allowlistManifest(bytes4[] memory selectors) internal returns (StdManifest) {
        IStdManifest.Entry[] memory wl = new IStdManifest.Entry[](1);
        wl[0] = IStdManifest.Entry({poolId: POOL_A, caller: KEEPER, selectors: selectors});
        StdManifest m =
            StdManifest(address(factory.newStdManifest(_config(CAP, RATE, false, address(0), address(0), wl))));
        // KEEPER is a registered manager, and m is installed so the registry classifies/consumes through it.
        hubRegistry.updateManager(POOL_A, KEEPER, true);
        hubRegistry.setManifest(POOL_A, m);
        return m;
    }

    function _selectors(bytes4 a) internal pure returns (bytes4[] memory s) {
        s = new bytes4[](1);
        s[0] = a;
    }

    function testAllowlistConfigStored() public {
        StdManifest m = _allowlistManifest(_selectors(IHub.updateSharePrice.selector));
        assertTrue(m.restricted(POOL_A, KEEPER));
        assertTrue(m.allowed(POOL_A, KEEPER, IHub.updateSharePrice.selector));
        assertFalse(m.allowed(POOL_A, KEEPER, IHub.notifyPool.selector));
        // An address with no entry is unrestricted.
        assertFalse(m.restricted(POOL_A, manager));
    }

    function testAllowlistedCallerCanCallAllowedSelector() public {
        StdManifest m = _allowlistManifest(_selectors(IHub.updateSharePrice.selector));
        // First price update has no baseline -> in policy; the confinement check passes.
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, _priceCall(1e18));
    }

    function testAllowlistedCallerBlockedFromOtherSelector() public {
        StdManifest m = _allowlistManifest(_selectors(IHub.updateSharePrice.selector));
        // notifyPool is normally in policy for anyone, but KEEPER is confined to updateSharePrice.
        vm.prank(address(hub));
        vm.expectRevert(IStdManifest.CallerNotAllowed.selector);
        m.enforce(POOL_A, KEEPER, abi.encodeWithSelector(IHub.notifyPool.selector, POOL_A, uint16(1), address(0)));
    }

    function testAllowlistedCallerCannotAuthorizeOtherSelector() public {
        _allowlistManifest(_selectors(IHub.updateSharePrice.selector));
        // Confinement also blocks authorize: KEEPER can't even queue an out-of-policy call outside its set.
        vm.prank(KEEPER);
        vm.expectRevert(IStdManifest.CallerNotAllowed.selector);
        hubRegistry.authorize(POOL_A, _setManifestCall(address(this)));
    }

    function testAllowlistComposesWithValueGuard() public {
        StdManifest m = _allowlistManifest(_selectors(IHub.updateSharePrice.selector));
        // Allowed selector still flows through the price guard: establish a baseline...
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, _priceCall(1e18));
        skip(1);

        // ...then a jump over the rate is out of policy (Unauthorized), not blocked by confinement.
        vm.prank(address(hub));
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        m.enforce(POOL_A, KEEPER, _priceCall(1e18 + 2e15));

        // KEEPER may authorize it (it is within its selector set) and run it after the delay.
        vm.prank(KEEPER);
        hubRegistry.authorize(POOL_A, _priceCall(1e18 + 2e15));
        skip(DELAY);
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, _priceCall(1e18 + 2e15));
    }

    function testAllowlistMultipleSelectors() public {
        bytes4[] memory sels = new bytes4[](2);
        sels[0] = IHub.notifySharePrice.selector;
        sels[1] = IHub.notifyAssetPrice.selector;
        StdManifest m = _allowlistManifest(sels);

        // Both listed notify selectors are allowed (and in policy by default).
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, abi.encodeWithSelector(IHub.notifySharePrice.selector, POOL_A, SC_A, uint16(1)));
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, abi.encodeWithSelector(IHub.notifyAssetPrice.selector, POOL_A, SC_A, uint128(0)));

        // A third, unlisted selector is blocked.
        vm.prank(address(hub));
        vm.expectRevert(IStdManifest.CallerNotAllowed.selector);
        m.enforce(POOL_A, KEEPER, _priceCall(1e18));
    }

    function testUnrestrictedCallerUnaffectedByAllowlist() public {
        StdManifest m = _allowlistManifest(_selectors(IHub.updateSharePrice.selector));
        // `manager` has no allowlist entry, so it follows normal policy: notifyPool stays in policy.
        vm.prank(address(hub));
        m.enforce(POOL_A, manager, abi.encodeWithSelector(IHub.notifyPool.selector, POOL_A, uint16(1), address(0)));
    }

    function testAllowlistIsPerPool() public {
        // KEEPER is confined in POOL_A but has no entry for another pool, so it is unconfined there.
        StdManifest m = _allowlistManifest(_selectors(IHub.updateSharePrice.selector));
        PoolId poolB = PoolId.wrap(2);
        assertFalse(m.restricted(poolB, KEEPER));

        // A selector blocked for KEEPER in POOL_A (notifyPool) is in policy for KEEPER in POOL_B.
        vm.prank(address(hub));
        m.enforce(poolB, KEEPER, abi.encodeWithSelector(IHub.notifyPool.selector, poolB, uint16(1), address(0)));
    }
}
