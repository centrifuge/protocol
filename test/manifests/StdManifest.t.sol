// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

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
import {ILocalCentrifugeId} from "../../src/core/messaging/interfaces/IGatewaySenders.sol";

import {UpdateRestrictionType} from "../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {IOnOffRamp} from "../../src/managers/spoke/interfaces/IOnOffRamp.sol";

import {ManagerAction} from "../../src/vaults/interfaces/IBatchRequestManager.sol";

import "forge-std/Test.sol";

import {IStdManifest} from "../../src/manifests/interfaces/IStdManifest.sol";
import {StdManifest, StdManifestFactory} from "../../src/manifests/StdManifest.sol";

contract StdManifestTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));

    // Selectors for the two updateSharePrice overloads (disambiguated; UPDATE_SHARE_PRICE_WITH_TIMESTAMP is ambiguous).
    bytes4 constant UPDATE_SHARE_PRICE_WITH_TIMESTAMP =
        bytes4(keccak256("updateSharePrice(uint64,bytes16,uint128,uint64)"));
    bytes4 constant UPDATE_SHARE_PRICE = bytes4(keccak256("updateSharePrice(uint64,bytes16,uint128)"));

    uint48 constant DELAY = 1 days;
    uint48 constant EXPIRY = 7 days;
    uint48 constant ESCALATION = 7 days;
    uint128 constant RATE = 1e15; // per second
    uint128 constant CAP = 5e17; // absolute per-update
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    IHub immutable hub = IHub(makeAddr("Hub"));
    address immutable sender = makeAddr("Sender");
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    address immutable supervisor = makeAddr("supervisor");
    address immutable brm = makeAddr("BRM");
    address immutable hook = makeAddr("bridgingHook");
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
        vm.mockCall(address(hub), abi.encodeWithSelector(IHub.sender.selector), abi.encode(sender));
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(ILocalCentrifugeId.localCentrifugeId.selector),
            abi.encode(LOCAL_CENTRIFUGE_ID)
        );
        factory = new StdManifestFactory(hub, multiAdapter, scm);
        manifest = StdManifest(address(factory.newStdManifest(_config(CAP, RATE, false, address(0), address(0)))));

        // Register the pool (manager becomes a manager; outsider is not) and install the manifest.
        hubRegistry.registerAsset(AssetId.wrap(1), 6);
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
            bridgingHook: hook,
            oracleValuation: address(0),
            contractUpdaterForwarder: contractUpdaterForwarder,
            allowlist: allowlist
        });
    }

    function _authId(bytes memory d) internal view returns (bytes32) {
        return hubRegistry.authId(POOL_A, d);
    }

    /// @dev Authorize `data` as a manager and return the classified delay (validAfter - now).
    function _delayOf(bytes memory d) internal returns (uint48) {
        hubRegistry.initiateAuthorization(POOL_A, manager, d);
        return hubRegistry.authorizedAfter(_authId(d)) - uint48(block.timestamp);
    }

    function _setManifestCall(address m) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHub.setManifest.selector, POOL_A, m);
    }

    /// @dev Manual price update (pool manager supplies explicit computedAt).
    function _priceCallWithTimestamp(uint128 raw) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UPDATE_SHARE_PRICE_WITH_TIMESTAMP, POOL_A, SC_A, D18.wrap(raw), uint64(0));
    }

    /// @dev Automated price update (SimplePriceManager, no computedAt in calldata).
    function _priceCall(uint128 raw) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(UPDATE_SHARE_PRICE, POOL_A, SC_A, D18.wrap(raw));
    }

    // ─── authorize flow (out-of-policy driven by the setManifest selector) ───────

    function testAuthorizeStoresValidAfter() public {
        bytes memory d = _setManifestCall(address(this));
        vm.expectEmit();
        emit IHubRegistry.AuthorizationScheduled(POOL_A, manager, _authId(d), uint48(block.timestamp) + ESCALATION, d);
        hubRegistry.initiateAuthorization(POOL_A, manager, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), block.timestamp + ESCALATION);
    }

    function testAuthorizeNotAuthorized() public {
        // authorize is ward-only; the manager check lives in Hub.initiateAuthorization.
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(outsider);
        hubRegistry.initiateAuthorization(POOL_A, manager, _setManifestCall(address(this)));
    }

    function testReauthorizePendingReverts() public {
        bytes memory d = _setManifestCall(address(this));
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        // Re-authorizing a pending auth reverts rather than silently resetting its maturity clock.
        vm.expectRevert(IHubRegistry.AlreadyAuthorized.selector);
        hubRegistry.initiateAuthorization(POOL_A, manager, d);
    }

    function testReauthorizeExpiredReverts() public {
        bytes memory d = _setManifestCall(address(this));
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        // Past maturity + expiry the auth is dead but enforce never cleared it, so re-authorizing
        // still reverts — it must be cancelled first.
        skip(ESCALATION + EXPIRY + 1);
        vm.expectRevert(IHubRegistry.AlreadyAuthorized.selector);
        hubRegistry.initiateAuthorization(POOL_A, manager, d);
    }

    function testCancelThenReauthorize() public {
        bytes memory d = _setManifestCall(address(this));
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        hubRegistry.cancelAuthorization(POOL_A, manager, d);

        // Once cancelled, the same call can be authorized again.
        hubRegistry.initiateAuthorization(POOL_A, manager, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), block.timestamp + ESCALATION);
    }

    function testAuthorizeInPolicyReverts() public {
        // An in-policy call has nothing to authorize; banking it would let a manager fire it later
        // once the same calldata drifts out of policy.
        bytes memory d = abi.encodeWithSelector(IHub.notifyPool.selector, POOL_A, uint16(1), address(0));
        vm.expectRevert(IHubRegistry.InPolicy.selector);
        hubRegistry.initiateAuthorization(POOL_A, manager, d);
    }

    function testCancelAuthorization() public {
        bytes memory d = _setManifestCall(address(this));
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        vm.expectEmit();
        emit IHubRegistry.AuthorizationCanceled(POOL_A, manager, _authId(d));
        hubRegistry.cancelAuthorization(POOL_A, manager, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), 0);
    }

    function testCancelNotAuthorized() public {
        // cancelAuthorization is ward-only; the manager check lives in Hub.cancelAuthorization.
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(outsider);
        hubRegistry.cancelAuthorization(POOL_A, manager, _setManifestCall(address(this)));
    }

    function testCancelNoAuthorizationReverts() public {
        // Cancelling a call that was never authorized fails loud rather than emitting a no-op event.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        hubRegistry.cancelAuthorization(POOL_A, manager, _setManifestCall(address(this)));
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
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        skip(ESCALATION - 1);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
    }

    function testEnforceOutOfPolicyMaturedConsumes() public {
        bytes memory d = _setManifestCall(address(this));
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

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
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        // Matured but the execution window has closed: fails closed, the auth is no longer valid.
        skip(ESCALATION + EXPIRY + 1);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
    }

    function testEnforceOutOfPolicyAtExpiryBoundaryConsumes() public {
        bytes memory d = _setManifestCall(address(this));
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        // The last instant of the window is still valid (inclusive upper bound).
        skip(ESCALATION + EXPIRY);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, d);
        assertEq(hubRegistry.authorizedAfter(_authId(d)), 0);
    }

    function testAuthorizationMatchesExactCalldata() public {
        hubRegistry.initiateAuthorization(POOL_A, manager, _setManifestCall(address(0xA)));
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

    // ─── restriction guard ────────────────────────────────────────────────────

    function _restrictionCall(bytes memory update) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IHub.updateRestriction.selector, POOL_A, SC_A, LOCAL_CENTRIFUGE_ID, update, uint128(0), address(0)
        );
    }

    function testFreezeRestrictionInPolicy() public view {
        // A canonical Freeze is strictly tightening, so it runs instantly (delay 0).
        bytes memory freeze = abi.encodePacked(uint8(UpdateRestrictionType.Freeze), bytes32(bytes20(who)));
        assertEq(manifest.classify(POOL_A, manager, _restrictionCall(freeze)), 0);
    }

    function testUnfreezeRestrictionNeedsAuthorization() public view {
        bytes memory unfreeze = abi.encodePacked(uint8(UpdateRestrictionType.Unfreeze), bytes32(bytes20(who)));
        assertEq(manifest.classify(POOL_A, manager, _restrictionCall(unfreeze)), DELAY);
    }

    function testMemberRestrictionNeedsAuthorization() public view {
        bytes memory member =
            abi.encodePacked(uint8(UpdateRestrictionType.Member), bytes32(bytes20(who)), uint64(1 days));
        assertEq(manifest.classify(POOL_A, manager, _restrictionCall(member)), DELAY);
    }

    function testMalformedRestrictionNeedsAuthorization() public view {
        // Too short (only the type byte) fails closed to delay.
        bytes memory short = abi.encodePacked(uint8(UpdateRestrictionType.Freeze));
        assertEq(manifest.classify(POOL_A, manager, _restrictionCall(short)), DELAY);

        // Canonical 33-byte length but an out-of-range type byte also fails closed to delay (no revert).
        bytes memory badType = abi.encodePacked(uint8(0xff), bytes32(bytes20(who)));
        assertEq(manifest.classify(POOL_A, manager, _restrictionCall(badType)), DELAY);
    }

    function testFreezeWithTrailingBytesNeedsAuthorization() public view {
        // A Freeze with one trailing byte is not the canonical 33-byte shape, so it stays out of policy.
        bytes memory freezePlus = abi.encodePacked(uint8(UpdateRestrictionType.Freeze), bytes32(bytes20(who)), uint8(0));
        assertEq(manifest.classify(POOL_A, manager, _restrictionCall(freezePlus)), DELAY);
    }

    // ─── constructor timelock validation ─────────────────────────────────

    function _timelockConfig(uint48 delay_, uint48 expiry_, uint48 escalation_)
        internal
        view
        returns (IStdManifest.Config memory c)
    {
        c = _config(CAP, RATE, false, address(0), address(0));
        c.delay = delay_;
        c.expiry = expiry_;
        c.escalation = escalation_;
    }

    function testConstructorRejectsZeroDelay() public {
        vm.expectRevert(IStdManifest.InvalidConfig.selector);
        new StdManifest(hub, multiAdapter, scm, _timelockConfig(0, EXPIRY, ESCALATION));
    }

    function testConstructorRejectsZeroExpiry() public {
        vm.expectRevert(IStdManifest.InvalidConfig.selector);
        new StdManifest(hub, multiAdapter, scm, _timelockConfig(DELAY, 0, ESCALATION));
    }

    function testConstructorRejectsEscalationEqualToDelay() public {
        vm.expectRevert(IStdManifest.InvalidConfig.selector);
        new StdManifest(hub, multiAdapter, scm, _timelockConfig(DELAY, EXPIRY, DELAY));
    }

    function testConstructorRejectsEscalationBelowDelay() public {
        vm.expectRevert(IStdManifest.InvalidConfig.selector);
        new StdManifest(hub, multiAdapter, scm, _timelockConfig(DELAY, EXPIRY, DELAY - 1));
    }

    // ─── share-price guard ─────────────────────────────────────────────────────────

    function testFirstPriceUpdateInPolicyAndCommits() public {
        // No baseline yet -> in policy; enforce commits the baseline timestamp.
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18));
        assertEq(manifest.lastPriceUpdate(POOL_A, SC_A), block.timestamp);
    }

    function testSmallPriceUpdateInPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline
        skip(100);

        // Tiny move, well under rate and cap.
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18 + 1e10));
    }

    function testRateLimitedPriceUpdateNeedsAuthorization() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline at T0
        skip(1); // 1 second later

        // delta 2e15 over 1s exceeds RATE (1e15/s); below CAP. Out of policy.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18 + 2e15));
    }

    function testAbsoluteCapHoldsAfterLongWait() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline
        skip(1e9); // huge elapsed -> rate would pass

        // delta 1e18 >= CAP (5e17): a single jump this large is out of policy regardless of time.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(2e18));
    }

    function testAbsoluteCapBoundaryExactlyAtCapIsOutOfPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline
        skip(1000); // large enough that RATE alone would not trigger at this delta

        // delta == CAP exactly: the >= comparison must still classify this as out of policy.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18 + CAP));
    }

    function testAbsoluteCapBoundaryJustUnderCapIsInPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline
        skip(1000); // keeps delta/elapsed well under RATE too

        // delta == CAP - 1: strictly below the cap, must stay in policy.
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18 + CAP - 1));
    }

    function testRateBoundaryExactlyAtThresholdIsOutOfPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline
        skip(100);

        // delta / elapsed == RATE exactly, and delta stays well under CAP so only the rate branch
        // can be responsible for classifying this out of policy.
        uint256 delta = uint256(RATE) * 100;
        assertLt(delta, CAP);
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(uint128(1e18 + delta)));
    }

    function testRateBoundaryJustUnderThresholdIsInPolicy() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline
        skip(100);

        // delta / elapsed just under RATE: must stay in policy.
        uint256 delta = uint256(RATE) * 100 - 1;
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(uint128(1e18 + delta)));
    }

    function testAuthorizeDoesNotMoveBaseline() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline at T0
        uint64 t0 = manifest.lastPriceUpdate(POOL_A, SC_A);

        skip(50);
        // Authorizing an out-of-policy price jump must NOT advance the baseline.
        hubRegistry.initiateAuthorization(POOL_A, manager, _priceCallWithTimestamp(2e18));
        assertEq(manifest.lastPriceUpdate(POOL_A, SC_A), t0);
    }

    function testSameBlockPriceUpdateNeedsAuthorization() public {
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18)); // baseline committed this block

        // A second update in the SAME block has zero elapsed time: out of policy even though the
        // move is tiny. This closes the chunk-many-sub-threshold-updates-in-one-tx bypass.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18 + 1e10));
    }

    function testPriceGuardDisabled() public {
        manifest = StdManifest(address(factory.newStdManifest(_config(0, 0, false, address(0), address(0)))));

        // Establish a baseline, then a huge same-block jump: with both guards off everything is in policy.
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(1e18));
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _priceCallWithTimestamp(100e18));
    }

    // ─── managerCall classification ───────────────────────────────────────────────

    function _managerCall(bytes32 target, bytes memory inner) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IHub.managerCall.selector, POOL_A, LOCAL_CENTRIFUGE_ID, target, inner, uint128(0), uint256(0), address(0)
        );
    }

    function testManagerCallToRequestManagerInPolicy() public {
        // managerCall targeting the configured request manager (BRM) is in policy: routine keeper ops run
        // synchronously, no authorization needed. The opaque payload is not inspected (target is pinned).
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _managerCall(bytes32(bytes20(brm)), abi.encode(uint8(1), bytes16(0))));
    }

    function testManagerCallToRequestManagerOnRemoteChainDelayed() public {
        // Target pins (BRM, bridging hook, forwarder) are local addresses with no cross-chain guarantee
        // (CREATE3 determinism is not a security invariant). A remote-dispatched managerCall must fall
        // through to delay even if the target byte-matches a local pin.
        bytes memory d = abi.encodeWithSelector(
            IHub.managerCall.selector,
            POOL_A,
            LOCAL_CENTRIFUGE_ID + 1,
            bytes32(bytes20(brm)),
            abi.encode(uint8(1), bytes16(0)),
            uint128(0),
            uint256(0),
            address(0)
        );
        assertEq(_delayOf(d), DELAY);
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

    function testManagerCallShortPayloadFailsClosed() public view {
        // A managerCall payload shorter than 224 bytes (the static ABI encoding of its 7 parameters)
        // must not revert during classify/authorize — it fails closed as out-of-policy (delay).
        bytes memory shortPayload = abi.encodePacked(IHub.managerCall.selector, new bytes(100)); // 4 + 100 = 104 bytes, well under 224
        assertEq(manifest.classify(POOL_A, manager, shortPayload), DELAY);
    }

    function testManagerCallTruncatedDynamicTailReverts() public {
        // A payload >= 224 bytes (past the length guard) can still revert on abi.decode: 224 only covers
        // the static head, but a validly-encoded call needs a further word for the dynamic `inner` bytes'
        // length (256 minimum). A payload truncated to 234 bytes has a head pointing past its own end, so
        // decode reverts. This is safe rather than a re-run of the malformed-payload DoS: classify() runs
        // inside authorize(), so the revert only aborts that authorize() call - nothing is stored, so there
        // is nothing later for {Supervisor._checkNotSelfRemoval} to freeze via a revert on cancellation.
        bytes memory full = _managerCall(bytes32(bytes20(makeAddr("someTarget"))), abi.encode(uint256(1), bytes32(0)));
        bytes memory truncated = new bytes(234);
        for (uint256 i; i < 234; i++) {
            truncated[i] = full[i];
        }
        vm.expectRevert();
        this.classifyExternal(truncated);
    }

    function classifyExternal(bytes calldata data) external view {
        manifest.classify(POOL_A, manager, data);
    }

    function testManagerCallToBridgingHookSetPausedInPolicy() public {
        // SetPaused (kind 0) to the configured bridging hook is instant — no authorization needed.
        bytes memory inner = abi.encode(uint8(0), bytes16("sc1"), true);
        vm.prank(address(hub));
        manifest.enforce(POOL_A, manager, _managerCall(bytes32(bytes20(hook)), inner));
    }

    function testManagerCallToBridgingHookSetRateLimitDelayed() public {
        // SetRateLimit (kind 1) to the bridging hook is still out of policy — needs authorization.
        bytes memory inner = abi.encode(uint8(1), bytes16("sc1"), uint16(2), uint128(5000e18), uint32(3600));
        assertEq(_delayOf(_managerCall(bytes32(bytes20(hook)), inner)), DELAY);
    }

    function testManagerCallToBridgingHookNotConfiguredDelayed() public {
        // When bridgingHook is address(0), a SetPaused payload to any target is still delayed.
        IStdManifest.Config memory cfg = _config(CAP, RATE, false, address(0), address(0));
        cfg.bridgingHook = address(0);
        StdManifest noHook = new StdManifest(hub, multiAdapter, scm, cfg);
        hubRegistry.setManifest(POOL_A, noHook);
        bytes memory inner = abi.encode(uint8(0), bytes16("sc1"), true);
        assertEq(_delayOf(_managerCall(bytes32(bytes20(hook)), inner)), DELAY);
        hubRegistry.setManifest(POOL_A, manifest);
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

    function testBrmUnknownActionKindDelayed() public {
        // A kind outside the known ManagerAction set (price-bearing or force-cancel) fails closed to
        // delay rather than being waved through in-policy - deny-by-default, not deny-by-exception.
        bytes memory inner = abi.encode(uint8(99), bytes16(0));
        assertEq(_classifyBrm(DEVIATION, inner), DELAY);
    }

    function testBrmMalformedShortPayloadDelayed() public {
        // A price-bearing kind whose payload is too short to hold the price word fails closed -> delay.
        bytes memory inner = abi.encode(uint8(ManagerAction.IssueShares), ShareClassId.unwrap(SC_A));
        assertEq(_classifyBrm(DEVIATION, inner), DELAY);
    }

    function testBrmIssueDustReferenceZeroPriceDelayed() public {
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector, POOL_A, SC_A),
            abi.encode(D18.wrap(1), uint64(0))
        );
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.IssueShares, 0)), DELAY);
    }

    function testBrmIssueDustReferenceTwoPriceDelayed() public {
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector, POOL_A, SC_A),
            abi.encode(D18.wrap(1), uint64(0))
        );
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.IssueShares, 2)), DELAY);
    }

    function testBrmIssueDustReferenceExactMatchInPolicy() public {
        // price=1 == ref=1: delta=0, always passes.
        vm.mockCall(
            address(scm),
            abi.encodeWithSelector(IShareClassManager.pricePoolPerShare.selector, POOL_A, SC_A),
            abi.encode(D18.wrap(1), uint64(0))
        );
        assertEq(_classifyBrm(DEVIATION, _brmShareAction(ManagerAction.IssueShares, 1)), 0);
    }

    // ─── contract-update classification (managerCall to the forwarder) ────────────

    function _updateContractCall(bytes32 target, bytes memory inner) internal view returns (bytes memory) {
        // A contract update is a `managerCall` to the contractUpdaterForwarder, carrying the scId + real
        // target + inner payload wrapped via {ContractUpdateLib.wrap}. The manifest sees the forwarder as
        // the target and classifies it as `delay` in `_checkManagerCall`.
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

    function testUpdateVaultNeedsAuthorization() public {
        // Every vault update (deploy/link/unlink) is timelocked.
        bytes memory d = abi.encodeWithSelector(IHub.updateVault.selector, POOL_A, SC_A, uint8(0));
        assertEq(_delayOf(d), DELAY);
    }

    function testUpdateCurrencyNeedsAuthorization() public {
        // Changing the pool currency is a structural config change and is timelocked.
        bytes memory d = abi.encodeWithSelector(IHub.updateCurrency.selector, POOL_A, AssetId.wrap(1));
        assertEq(_delayOf(d), DELAY);
    }

    function _managerCall(ManagerKind kind, bytes32 who_, bool canManage) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHub.updateManager.selector, POOL_A, uint16(1), kind, who_, canManage, address(0));
    }

    function testGrantAdaptersManagerNeedsAuthorization() public {
        assertEq(_delayOf(_managerCall(ManagerKind.Adapter, bytes32(bytes20(who)), true)), DELAY);
    }

    function testRevokeAdaptersManagerNeedsAuthorization() public {
        assertEq(_delayOf(_managerCall(ManagerKind.Adapter, bytes32(bytes20(who)), false)), DELAY);
    }

    // ─── balance-sheet manager classification ─────────────────────────────────────

    function testGrantSpokeManagerNeedsAuthorization() public {
        assertEq(_delayOf(_managerCall(ManagerKind.Spoke, bytes32(bytes20(who)), true)), DELAY);
    }

    function testRevokeSpokeManagerNeedsAuthorization() public {
        assertEq(_delayOf(_managerCall(ManagerKind.Spoke, bytes32(bytes20(who)), false)), DELAY);
    }

    // ─── setAdapters classification ───────────────────────────────────────────────

    function _setAdaptersCall(IAdapter[] memory local, bytes32[] memory remote) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            IHub.setAdapters.selector, POOL_A, uint16(1), local, remote, uint8(0), uint8(0), address(0)
        );
    }

    function testSetAdaptersAlwaysOutOfPolicy() public {
        // setAdapters is always `delay`, regardless of which local/remote adapters are proposed: neither
        // is validated on-chain (see {StdManifest._classify}), so a sentinel reviewing the pending
        // authorization is the only safeguard.
        IAdapter[] memory local = new IAdapter[](1);
        local[0] = IAdapter(makeAddr("adapter"));
        bytes32[] memory remote = new bytes32[](1);
        remote[0] = CastLib.toBytes32(makeAddr("foreignAdapter"));
        assertEq(_delayOf(_setAdaptersCall(local, remote)), DELAY);
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

    function testOnchainPriceManagerFirstUpdateInPolicy() public {
        StdManifest m = _onchainManifest();
        // No baseline yet -> first update from SimplePriceManager is in policy regardless of the price.
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(100e18));
        assertEq(m.lastPriceUpdate(POOL_A, SC_A), block.timestamp);
    }

    function testOnchainPriceManagerSmallUpdateInPolicy() public {
        StdManifest m = _onchainManifest();
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18)); // baseline
        skip(100);

        // Tiny move, well under rate and cap.
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18 + 1e10));
    }

    function testOnchainPriceManagerRateLimitedNeedsAuthorization() public {
        StdManifest m = _onchainManifest();
        hubRegistry.setManifest(POOL_A, m);
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18)); // baseline at T0
        skip(1); // 1 second later

        // delta 2e15 over 1s exceeds RATE (1e15/s); below CAP. Out of policy.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18 + 2e15));
    }

    function testOnchainPriceManagerCapExceededNeedsAuthorization() public {
        StdManifest m = _onchainManifest();
        hubRegistry.setManifest(POOL_A, m);
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18)); // baseline
        skip(1e9); // huge elapsed -> rate would pass

        // delta 1e18 >= CAP (5e17): out of policy regardless of elapsed time.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(2e18));
    }

    function testOnchainPriceManagerSameBlockNeedsAuthorization() public {
        StdManifest m = _onchainManifest();
        hubRegistry.setManifest(POOL_A, m);
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18)); // baseline committed this block

        // A second update in the same block has zero elapsed: out of policy.
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18 + 1e10));
    }

    function testOnchainPriceManagerOutOfPolicyCanBePreauthorized() public {
        StdManifest m = _onchainManifest();
        hubRegistry.setManifest(POOL_A, m);
        address spm = m.simplePriceManager();
        vm.prank(address(hub));
        m.enforce(POOL_A, spm, _priceCall(1e18));
        skip(1);

        // Pool manager pre-authorizes using the no-timestamp calldata. Since computedAt is absent,
        // the authorization id is stable and matches whatever block SimplePriceManager executes in.
        bytes memory d = _priceCall(1e18 + 2e15);
        hubRegistry.initiateAuthorization(POOL_A, manager, d);

        skip(DELAY);
        vm.prank(address(hub));
        m.enforce(POOL_A, spm, d);
    }

    function testOnchainPriceManagerPreauthorizationBlocksNonPriceManager() public {
        StdManifest m = _onchainManifest();
        hubRegistry.setManifest(POOL_A, m);
        address spm = m.simplePriceManager();
        vm.prank(address(hub));
        m.enforce(POOL_A, spm, _priceCall(1e18));
        skip(1);

        bytes memory d = _priceCall(1e18 + 2e15);
        hubRegistry.initiateAuthorization(POOL_A, manager, d);
        skip(DELAY);

        // Even with a valid pre-authorization, a non-SimplePriceManager caller is blocked at enforce.
        vm.expectRevert(IStdManifest.OnchainAccountingOnly.selector);
        vm.prank(address(hub));
        m.enforce(POOL_A, manager, d);
    }

    function testOnchainPriceManagerGuardDisabled() public {
        StdManifest m = StdManifest(address(factory.newStdManifest(_config(0, 0, true, NAV, PRICE))));

        // With both guards off, SimplePriceManager can make any same-block jump.
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(1e18));
        vm.prank(address(hub));
        m.enforce(POOL_A, PRICE, _priceCall(100e18));
    }

    function testAccountingSelectorTimelockedWhenFlagOff() public {
        // With on-chain accounting off, manual accounting is out of policy (timelocked), not instant.
        assertEq(_delayOf(abi.encodeWithSelector(IHub.updateJournal.selector, POOL_A)), DELAY);
        assertEq(_delayOf(abi.encodeWithSelector(IHub.createAccount.selector, POOL_A)), DELAY);
    }

    // ─── oracle valuation ─────────────────────────────────────────────────────────

    address constant ORACLE = address(0xD4);

    function _oracleManifest(bool onchain) internal returns (StdManifest) {
        IStdManifest.Config memory cfg =
            _config(CAP, RATE, onchain, onchain ? NAV : address(0), onchain ? PRICE : address(0));
        cfg.oracleValuation = ORACLE;
        return StdManifest(address(factory.newStdManifest(cfg)));
    }

    function _updateHoldingValueCall() internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IHub.updateHoldingValue.selector, POOL_A, SC_A, AssetId.wrap(1));
    }

    function testOracleValuationUpdateHoldingValueInPolicy() public {
        StdManifest m = _oracleManifest(false);
        vm.prank(address(hub));
        m.enforce(POOL_A, ORACLE, _updateHoldingValueCall());
    }

    function testOracleValuationUpdateHoldingValueInPolicyOnchainMode() public {
        StdManifest m = _oracleManifest(true);
        hubRegistry.setManifest(POOL_A, m);
        vm.prank(address(hub));
        m.enforce(POOL_A, ORACLE, _updateHoldingValueCall());
    }

    function testOracleValuationOtherSelectorStillDelayed() public {
        StdManifest m = _oracleManifest(false);
        hubRegistry.setManifest(POOL_A, m);
        hubRegistry.updateManager(POOL_A, ORACLE, true);
        assertEq(
            _delayOf(
                abi.encodeWithSelector(IHub.updateHoldingValuation.selector, POOL_A, SC_A, AssetId.wrap(1), address(0))
            ),
            DELAY
        );
    }

    function testOracleValuationNotConfiguredUpdateHoldingValueDelayed() public {
        assertEq(_delayOf(_updateHoldingValueCall()), DELAY);
    }

    function testOracleValuationStoredOnManifest() public {
        StdManifest m = _oracleManifest(false);
        assertEq(m.oracleValuation(), ORACLE);
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
        StdManifest m = _allowlistManifest(_selectors(UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        assertTrue(m.restricted(POOL_A, KEEPER));
        assertTrue(m.allowed(POOL_A, KEEPER, UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        assertFalse(m.allowed(POOL_A, KEEPER, IHub.notifyPool.selector));
        // An address with no entry is unrestricted.
        assertFalse(m.restricted(POOL_A, manager));
    }

    function testAllowlistedCallerCanCallAllowedSelector() public {
        StdManifest m = _allowlistManifest(_selectors(UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        // First price update has no baseline -> in policy; the confinement check passes.
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, _priceCallWithTimestamp(1e18));
    }

    function testAllowlistedCallerBlockedFromOtherSelector() public {
        StdManifest m = _allowlistManifest(_selectors(UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        // notifyPool is normally in policy for anyone, but KEEPER is confined to updateSharePrice.
        vm.prank(address(hub));
        vm.expectRevert(IStdManifest.CallerNotAllowed.selector);
        m.enforce(POOL_A, KEEPER, abi.encodeWithSelector(IHub.notifyPool.selector, POOL_A, uint16(1), address(0)));
    }

    function testAllowlistedCallerCannotAuthorizeOtherSelector() public {
        _allowlistManifest(_selectors(UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        // Confinement also blocks authorize: KEEPER can't even queue an out-of-policy call outside its set.
        vm.expectRevert(IStdManifest.CallerNotAllowed.selector);
        hubRegistry.initiateAuthorization(POOL_A, KEEPER, _setManifestCall(address(this)));
    }

    function testAllowlistComposesWithValueGuard() public {
        StdManifest m = _allowlistManifest(_selectors(UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        // Allowed selector still flows through the price guard: establish a baseline...
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, _priceCallWithTimestamp(1e18));
        skip(1);

        // ...then a jump over the rate is out of policy (Unauthorized), not blocked by confinement.
        vm.prank(address(hub));
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        m.enforce(POOL_A, KEEPER, _priceCallWithTimestamp(1e18 + 2e15));

        // KEEPER may authorize it (it is within its selector set) and run it after the delay.
        hubRegistry.initiateAuthorization(POOL_A, KEEPER, _priceCallWithTimestamp(1e18 + 2e15));
        skip(DELAY);
        vm.prank(address(hub));
        m.enforce(POOL_A, KEEPER, _priceCallWithTimestamp(1e18 + 2e15));
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
        m.enforce(POOL_A, KEEPER, _priceCallWithTimestamp(1e18));
    }

    function testUnrestrictedCallerUnaffectedByAllowlist() public {
        StdManifest m = _allowlistManifest(_selectors(UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        // `manager` has no allowlist entry, so it follows normal policy: notifyPool stays in policy.
        vm.prank(address(hub));
        m.enforce(POOL_A, manager, abi.encodeWithSelector(IHub.notifyPool.selector, POOL_A, uint16(1), address(0)));
    }

    function testAllowlistIsPerPool() public {
        // KEEPER is confined in POOL_A but has no entry for another pool, so it is unconfined there.
        StdManifest m = _allowlistManifest(_selectors(UPDATE_SHARE_PRICE_WITH_TIMESTAMP));
        PoolId poolB = PoolId.wrap(2);
        assertFalse(m.restricted(poolB, KEEPER));

        // A selector blocked for KEEPER in POOL_A (notifyPool) is in policy for KEEPER in POOL_B.
        vm.prank(address(hub));
        m.enforce(poolB, KEEPER, abi.encodeWithSelector(IHub.notifyPool.selector, poolB, uint16(1), address(0)));
    }
}
