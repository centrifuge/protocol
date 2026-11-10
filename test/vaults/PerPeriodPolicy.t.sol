// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {IERC8161DepositTransferable} from "../../src/misc/interfaces/IERC8161.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {
    IVaultRequestManager,
    IVaultDepositCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {PerPeriodPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {VaultRequestIdLib} from "../../src/vaults/libraries/VaultRequestIdLib.sol";
import {IPerPeriodPolicy} from "../../src/vaults/policies/interfaces/IRequestPolicies.sol";
import {
    IAsyncVault,
    IVaultErrors,
    IVaultEvents,
    Bucket,
    VaultConfig,
    VaultPlugins
} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IRoleHook} from "../../src/token/interfaces/IRoleHook.sol";
import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev A degenerate policy that pins every request to one shared bucket and always allows a
///      flush, used to reach the vault's sealed-bucket guard directly (a correct batching policy
///      never routes a contribution into an already-flushed bucket).
contract PinnedSharedPolicy is IRequestPolicy {
    function onRequest(address, address, address, bool, uint128) external pure returns (bytes32) {
        return bytes32(uint256(1));
    }

    function isClosed(address, bytes32) external pure returns (bool) {
        return true;
    }

    function supportsTransfers() external pure returns (bool) {
        return true;
    }

    function maxOpenBuckets() external pure returns (uint256) {
        return 1;
    }

    function isBatched() external pure returns (bool) {
        return true;
    }
}

contract PerPeriodPolicyTest is Test {
    using VaultRequestIdLib for address;

    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);
    uint64 constant WINDOW = 100;
    uint256 constant BASE_TS = 1_000_000;

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address actionHook = address(new IsContract());
    address router = address(new IsContract());
    address oracle = address(new IsContract());
    address instantPolicy = address(new IsContract());
    address escrow = makeAddr("escrow");

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);
    PerPeriodPolicy requestPolicy = new PerPeriodPolicy(WINDOW, 0, 0, 0);

    Vault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vm.warp(BASE_TS);

        _mock(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));

        VaultConfig memory config = VaultConfig({
            foldHorizon: 0,
            spoke: ISpoke(spoke),
            spokeRegistry: ISpokeRegistry(spokeRegistry),
            plugins: VaultPlugins({
                oracle: IVaultOracle(oracle),
                instantPolicy: IInstantPolicy(instantPolicy),
                requestPolicy: IRequestPolicy(address(requestPolicy)),
                liquidityRoute: ILiquidityRoute(address(0)),
                settlementObserver: ISettlementObserver(address(0))
            })
        });

        vault = new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);

        _mock(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        _mock(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));
        share.setHook(actionHook);
        _mock(actionHook, abi.encodeWithSelector(IRoleHook.onRoles.selector), abi.encode(IRoleHook.onRoles.selector));
        _mock(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), abi.encode(true));
        _mock(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(true));
        _mock(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        _mock(router, abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");
        _mock(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));

        bytes4[5] memory voids = [
            ISpoke.noteDeposit.selector,
            ISpoke.reserve.selector,
            ISpoke.unreserve.selector,
            ISpoke.issue.selector,
            ISpoke.withdrawShares.selector
        ];
        for (uint256 i; i < voids.length; i++) {
            _mock(spoke, abi.encodeWithSelector(voids[i]), "");
        }
    }

    // --- helpers ---

    function _mock(address target, bytes memory data, bytes memory ret) internal {
        vm.mockCall(target, data, ret);
    }

    /// @dev The deposit-side bucket of the current window, zero before the window's first request.
    function _depositLocalId() internal view returns (uint96) {
        bytes32 key = requestPolicy.onRequest(address(vault), address(0), address(0), true, 0);
        return IAsyncVault(address(vault)).bucketOf(key, true);
    }

    function _requestDeposit(address who, uint128 assets) internal {
        vm.prank(who);
        IAsyncVault(address(vault)).requestDeposit(assets, who, who);
    }

    function _fulfillDeposit(uint96 localId, uint128 assets, uint128 shares_) internal {
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, assets, shares_);
    }

    function _maxMint(address who) internal view returns (uint256 maxMint) {
        maxMint = IAsyncVault(address(vault)).claimableMint(who);
    }

    function _reqId(uint96 localId) internal view returns (uint256) {
        return uint256(VaultRequestIdLib.from(address(vault), localId).raw());
    }

    function _pending(uint256 requestId, address who) internal view returns (uint256) {
        return IAsyncVault(address(vault)).pendingDepositRequest(requestId, who);
    }

    // --- tests ---

    /// @dev The vault sends a side's previous batch when a request opens the next one, but only once the policy reports
    ///      it closed: under a notice the previous window can still be open, and then it waits for a keeper.
    function testANewBatchSendsThePreviousOneOnlyOnceItIsClosed() public {
        Vault noticed = _vaultWith(address(new PerPeriodPolicy(WINDOW, 0, 30, 0)));

        vm.warp(BASE_TS + 69);
        vm.prank(alice);
        IAsyncVault(address(noticed)).requestDeposit(1e6, alice, alice);
        vm.warp(BASE_TS + 70);
        vm.prank(alice);
        IAsyncVault(address(noticed)).requestDeposit(1e6, alice, alice);
        assertFalse(IAsyncVault(address(noticed)).bucket(1).flushed, "the previous window is still open");

        vm.warp(BASE_TS + WINDOW);
        IAsyncVault(address(noticed)).flushRequest(1);
        assertTrue(IAsyncVault(address(noticed)).bucket(1).flushed, "a keeper sends it once it closes");

        vm.warp(BASE_TS + 3 * WINDOW);
        vm.prank(alice);
        IAsyncVault(address(noticed)).requestDeposit(1e6, alice, alice);
        assertTrue(IAsyncVault(address(noticed)).bucket(2).flushed, "the next batch sends the closed one");
    }

    /// @dev Two contributors share one window; after the window closes and the hub fulfills the
    ///      whole batch, each folds their pro-rata share.
    function testSharedBucketFoldsProRata() public {
        _requestDeposit(alice, 1_000e6);
        _requestDeposit(bob, 3_000e6);
        uint96 localId = _depositLocalId();

        assertEq(IAsyncVault(address(vault)).bucket(localId).queued, 4_000e6, "batched into one bucket");

        // Roll past the window and close the bucket permissionlessly.
        vm.warp(BASE_TS + WINDOW);
        IAsyncVault(address(vault)).flushRequest(localId);
        assertTrue(IAsyncVault(address(vault)).bucket(localId).flushed, "bucket sealed on flush");

        // Hub fulfills the full 4000 assets -> 4000e18 shares at 1:1.
        _fulfillDeposit(localId, 4_000e6, 4_000e18);

        IAsyncVault(address(vault)).foldRequest(localId, alice);
        IAsyncVault(address(vault)).foldRequest(localId, bob);
        assertEq(_maxMint(alice), 1_000e18, "alice pro-rata 1/4");
        assertEq(_maxMint(bob), 3_000e18, "bob pro-rata 3/4");
    }

    /// @dev A contribution inside a shared window bucket is transferable: the policy keys buckets by
    ///      window and side, never by controller, so it has nothing to remap, and the bucket's `total`
    ///      is untouched so the other contributor's slice does not move. Carol takes on Alice's quarter
    ///      and settles on it.
    function testSharedBucketContributionIsTransferable() public {
        _requestDeposit(alice, 1_000e6);
        _requestDeposit(bob, 3_000e6);
        uint96 localId = _depositLocalId();

        address carol = makeAddr("carol");
        vm.prank(alice);
        IAsyncVault(address(vault)).transferDepositRequest(_reqId(localId), alice, carol);

        assertEq(IAsyncVault(address(vault)).contribution(localId, alice).amount, 0, "alice emptied");
        assertEq(IAsyncVault(address(vault)).contribution(localId, carol).amount, 1_000e6, "carol holds it");
        assertEq(IAsyncVault(address(vault)).bucket(localId).total, 4_000e6, "denominator untouched");

        vm.warp(BASE_TS + WINDOW);
        IAsyncVault(address(vault)).flushRequest(localId);
        _fulfillDeposit(localId, 4_000e6, 4_000e18);

        IAsyncVault(address(vault)).foldRequest(localId, carol);
        IAsyncVault(address(vault)).foldRequest(localId, bob);
        assertEq(_maxMint(carol), 1_000e18, "carol settles on the transferred quarter");
        assertEq(_maxMint(bob), 3_000e18, "bob unaffected");
        assertEq(_maxMint(alice), 0, "alice keeps nothing");
    }

    /// @dev A round trip through another controller inside one window lands on the same local id. The
    ///      way back is carol's transfer to alice, which enters alice's horizon again and is counted exactly once.
    function testATransferredBackPositionIsCountedOnce() public {
        _requestDeposit(alice, 1_000e6);
        _requestDeposit(bob, 3_000e6);
        uint96 localId = _depositLocalId();

        address carol = makeAddr("carol");
        vm.prank(alice);
        IAsyncVault(address(vault)).transferDepositRequest(_reqId(localId), alice, carol);
        vm.prank(carol);
        IAsyncVault(address(vault)).transferDepositRequest(_reqId(localId), carol, alice);

        assertEq(IAsyncVault(address(vault)).contribution(localId, alice).amount, 1_000e6, "one contribution, back");

        vm.warp(BASE_TS + WINDOW);
        IAsyncVault(address(vault)).flushRequest(localId);
        _fulfillDeposit(localId, 4_000e6, 4_000e18);

        assertEq(
            IAsyncVault(address(vault)).claimableDepositRequest(0, alice),
            1_000e6,
            "back in her horizon, so claimable at once"
        );
        assertEq(_pending(0, alice), 0, "and no longer pending");
        assertEq(IAsyncVault(address(vault)).maxMint(bob), 3_000e18, "bob's own window is claimable");

        IAsyncVault(address(vault)).foldRequest(localId, alice);
        assertEq(IAsyncVault(address(vault)).maxMint(alice), 1_000e18, "alice's quarter, counted once");
        assertEq(_pending(0, alice), 0);

        uint256 claimable = IAsyncVault(address(vault)).maxMint(alice);
        vm.prank(alice);
        IAsyncVault(address(vault)).mint(claimable, alice, alice);
    }

    /// @dev Pending views drop the settled-but-unfolded portion of a shared bucket, so a
    ///      contributor's pending reflects settlement even before they fold or claim.
    function testPendingReflectsSettlementBeforeFold() public {
        _requestDeposit(alice, 1_000e6);
        _requestDeposit(bob, 3_000e6);
        uint96 localId = _depositLocalId();

        vm.warp(BASE_TS + WINDOW);
        IAsyncVault(address(vault)).flushRequest(localId);

        // Half the batch settles; no one has folded yet.
        _fulfillDeposit(localId, 2_000e6, 2_000e18);

        // Aggregate and per-request pending both drop the settled pro-rata half.
        assertEq(_pending(0, alice), 500e6, "alice aggregate pending net of settlement");
        assertEq(_pending(_reqId(localId), alice), 500e6, "alice bucket pending net of settlement");
        assertEq(_pending(0, bob), 1_500e6, "bob aggregate pending net of settlement");
        assertEq(_pending(_reqId(localId), bob), 1_500e6, "bob bucket pending net of settlement");

        // Full settlement drives pending to zero without any fold.
        _fulfillDeposit(localId, 2_000e6, 2_000e18);
        assertEq(_pending(0, alice), 0, "alice fully settled");
        assertEq(_pending(_reqId(localId), bob), 0, "bob fully settled");

        // The ledger view reports the settled claim before anyone folds, not an empty position.
        uint256 settledMint = IAsyncVault(address(vault)).claimableMint(alice);
        assertEq(settledMint, 1_000e18, "the claimable view shows the unfolded claim");
        assertEq(_pending(0, alice), 0, "and nothing still pending");

        // Folding realizes the claim without double-counting the already-dropped pending.
        IAsyncVault(address(vault)).foldRequest(localId, alice);
        assertEq(_pending(0, alice), 0, "alice pending stays zero after fold");
        assertEq(_maxMint(alice), 1_000e18, "alice full claim");
        settledMint = IAsyncVault(address(vault)).claimableMint(alice);
        assertEq(settledMint, 1_000e18, "folding does not change what the claimable view reports");
    }

    /// @dev The open window's bucket cannot be flushed, so its pro-rata denominator can never be
    ///      sealed while contributions are still arriving (the core fund-lock guard).
    function testOpenWindowCannotBeFlushed() public {
        _requestDeposit(alice, 1_000e6);
        uint96 localId = _depositLocalId();

        vm.expectRevert(IVaultErrors.BucketStillOpen.selector);
        IAsyncVault(address(vault)).flushRequest(localId);
    }

    /// @dev Once a window closes, a late request lands in the next window's fresh bucket rather
    ///      than growing the sealed bucket's denominator.
    function testLateRequestRoutesToNextWindow() public {
        _requestDeposit(alice, 1_000e6);
        uint96 first = _depositLocalId();

        // Bob's request opens the new window and closes the old one.
        vm.warp(BASE_TS + WINDOW);
        _requestDeposit(bob, 1_000e6);
        uint96 second = _depositLocalId();
        assertTrue(second != first, "window advanced");

        Bucket memory b1 = IAsyncVault(address(vault)).bucket(first);
        assertTrue(b1.flushed, "old bucket sealed");
        assertEq(b1.queued, 0, "old bucket flushed");
        assertEq(IAsyncVault(address(vault)).contribution(first, bob).amount, 0, "bob not in old bucket");

        Bucket memory b2 = IAsyncVault(address(vault)).bucket(second);
        assertFalse(b2.flushed, "new bucket still open");
        assertEq(b2.queued, 1_000e6, "bob in new bucket");
        assertEq(b1.total, 1_000e6, "sealed denominator unchanged by late request");
    }

    function testAWindowAKeeperFlushedDoesNotBlockTheNext() public {
        _requestDeposit(alice, 1_000e6);
        uint96 first = _depositLocalId();

        vm.warp(BASE_TS + WINDOW);
        IAsyncVault(address(vault)).flushRequest(first);
        _requestDeposit(bob, 1_000e6);

        assertTrue(_depositLocalId() != first, "bob opened the next window");
        assertEq(IAsyncVault(address(vault)).bucket(first).queued, 0, "nothing sent twice");
    }

    /// @dev Partial fulfillments fold incrementally against a frozen denominator without
    ///      underflowing, even when a second contributor folds between the two settlements.
    function testIncrementalFoldNoUnderflow() public {
        _requestDeposit(alice, 1_000e6);
        _requestDeposit(bob, 1_000e6);
        uint96 localId = _depositLocalId();

        vm.warp(BASE_TS + WINDOW);
        IAsyncVault(address(vault)).flushRequest(localId);

        // First half settles; alice folds her share.
        _fulfillDeposit(localId, 1_000e6, 1_000e18);
        IAsyncVault(address(vault)).foldRequest(localId, alice);
        assertEq(_maxMint(alice), 500e18, "alice half of first tranche");

        // Second half settles; both fold the remainder. Denominator stayed 2000, so alice's
        // cumulative pro-rata only grows.
        _fulfillDeposit(localId, 1_000e6, 1_000e18);
        IAsyncVault(address(vault)).foldRequest(localId, alice);
        IAsyncVault(address(vault)).foldRequest(localId, bob);
        assertEq(_maxMint(alice), 1_000e18, "alice full share, no underflow");
        assertEq(_maxMint(bob), 1_000e18, "bob full share");
    }

    /// @dev Defense in depth: even if a policy misroutes a contribution into an already-flushed
    ///      shared bucket, the vault rejects it so the denominator cannot grow after settlement.
    function testSealedBucketRejectsContribution() public {
        PinnedSharedPolicy pinned = new PinnedSharedPolicy();
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );

        // Rebuild a vault wired to the pinned policy.
        VaultConfig memory config = VaultConfig({
            foldHorizon: 0,
            spoke: ISpoke(spoke),
            spokeRegistry: ISpokeRegistry(spokeRegistry),
            plugins: VaultPlugins({
                oracle: IVaultOracle(oracle),
                instantPolicy: IInstantPolicy(instantPolicy),
                requestPolicy: IRequestPolicy(address(pinned)),
                liquidityRoute: ILiquidityRoute(address(0)),
                settlementObserver: ISettlementObserver(address(0))
            })
        });
        Vault pinnedVault = new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);

        vm.prank(alice);
        IAsyncVault(address(pinnedVault)).requestDeposit(1_000e6, alice, alice);
        IAsyncVault(address(pinnedVault)).flushRequest(1);

        vm.prank(bob);
        vm.expectRevert(IVaultErrors.BucketSealed.selector);
        IAsyncVault(address(pinnedVault)).requestDeposit(1_000e6, bob, bob);
    }

    /// @dev The window cutoff is a configurable phase offset, so a pool can close daily at a chosen
    ///      time of day rather than at the epoch-aligned boundary. The window covering BASE_TS (a
    ///      period multiple) then closes at BASE_TS + offset.
    function testConfigurableCutoff() public {
        uint64 offset = 30;
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, offset, 0, 0);
        assertEq(policy.window(), WINDOW, "window set");
        assertEq(policy.offset(), offset, "offset set");

        bytes32 id = policy.onRequest(address(vault), alice, alice, true, 1_000e6);
        assertTrue(policy.isBatched(), "batched");
        assertFalse(policy.isClosed(address(vault), id), "open at request");

        vm.warp(BASE_TS + offset - 1);
        assertFalse(policy.isClosed(address(vault), id), "still open just before cutoff");

        vm.warp(BASE_TS + offset);
        assertTrue(policy.isClosed(address(vault), id), "flushable at cutoff");

        // A request at the cutoff opens the next window's fresh bucket.
        bytes32 next = policy.onRequest(address(vault), bob, bob, true, 1_000e6);
        assertTrue(next != id, "next window after cutoff");
    }

    /// @dev A window long after another gets a bucket of its own, and neither the request that joins it nor the
    ///      sealed earlier bucket is disturbed.
    function testAWindowLongAfterGetsItsOwnBucket() public {
        _requestDeposit(alice, 1_000e6);
        uint96 first = _depositLocalId();

        vm.warp(BASE_TS + 64 * WINDOW);
        _requestDeposit(alice, 1_000e6);
        uint96 later = _depositLocalId();
        assertTrue(later != first, "a new bucket");

        _requestDeposit(bob, 500e6);
        assertEq(_depositLocalId(), later, "a second request of the window joins it");
        assertEq(IAsyncVault(address(vault)).bucket(later).total, 1_500e6, "the new bucket holds both");
        assertEq(IAsyncVault(address(vault)).bucket(first).total, 1_000e6, "the old one is untouched");
        assertTrue(IAsyncVault(address(vault)).bucket(first).flushed, "and was sealed by the new window");
    }

    /// @dev Every window across more than a lap opens one bucket, shared by everything requested in it.
    function testEveryWindowAcrossALapOpensOneSharedBucket() public {
        uint96 previous;
        for (uint256 i; i < 70; i++) {
            vm.warp(BASE_TS + i * WINDOW);
            _requestDeposit(alice, 1e6);
            uint96 id = _depositLocalId();
            assertTrue(id != previous, "a window opened a new bucket");
            _requestDeposit(bob, 1e6);
            assertEq(_depositLocalId(), id, "the second request joined the window's bucket");
            assertEq(IAsyncVault(address(vault)).bucket(id).total, 2e6, "the bucket is the window's alone");
            previous = id;
        }
    }

    function testInvalidOffsetReverts() public {
        vm.expectRevert(IPerPeriodPolicy.InvalidOffset.selector);
        new PerPeriodPolicy(WINDOW, WINDOW, 0, 0);
    }

    function _noticeVault() internal returns (address vault_) {
        vault_ = makeAddr("noticeVault");
    }

    function _request(PerPeriodPolicy policy, address vault_, bool isDeposit) internal view returns (bytes32) {
        return policy.onRequest(vault_, alice, alice, isDeposit, 1e6);
    }

    /// @dev A redeem made at `t` joins the window that holds `t + notice` and can be flushed once that window closes,
    ///      so the notice is a wait of at least `notice`. Deposits, with no notice, join the open window.
    function testARedeemWaitsForItsNoticeToRunBeforeItsWindowCloses() public {
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, 0, 0, 150);
        address vault_ = _noticeVault();

        bytes32 redeem = _request(policy, vault_, false);
        bytes32 deposit = _request(policy, vault_, true);

        // The redeem executes in the window that holds BASE_TS + 150, which closes at BASE_TS + 200
        vm.warp(BASE_TS + WINDOW);
        assertTrue(policy.isClosed(vault_, deposit), "the deposit window closed");
        assertFalse(policy.isClosed(vault_, redeem), "the notice has not run");
        vm.warp(BASE_TS + 199);
        assertFalse(policy.isClosed(vault_, redeem), "one second short of the window close");
        vm.warp(BASE_TS + 200);
        assertTrue(policy.isClosed(vault_, redeem), "flushable at the first window close after the notice");
    }

    function testRedeemsJoinTheBucketOfTheWindowTheirNoticeLandsIn() public {
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, 0, 0, 150);
        address vault_ = _noticeVault();

        bytes32 first = _request(policy, vault_, false);
        vm.warp(BASE_TS + 40);
        assertEq(_request(policy, vault_, false), first, "t + 150 is still in the same window");
        vm.warp(BASE_TS + 50);
        bytes32 second = _request(policy, vault_, false);
        assertTrue(second != first, "t + 150 is in the next window");

        // Both buckets are open at once, and the earlier one is not flushable before its own window closes
        vm.warp(BASE_TS + 200);
        assertTrue(policy.isClosed(vault_, first));
        assertFalse(policy.isClosed(vault_, second));
        vm.warp(BASE_TS + 300);
        assertTrue(policy.isClosed(vault_, second));
    }

    /// @dev With a notice under one window the notice is a cutoff: a request in the last `notice` seconds before a
    ///      window closes joins the next one.
    function testADepositNoticeIsACutoffBeforeEachClose() public {
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, 0, 30, 0);
        address vault_ = _noticeVault();

        vm.warp(BASE_TS + 69);
        bytes32 before = _request(policy, vault_, true);
        vm.warp(BASE_TS + 70);
        bytes32 after_ = _request(policy, vault_, true);

        assertTrue(before != after_, "the cutoff splits the window");
        vm.warp(BASE_TS + 100);
        assertTrue(policy.isClosed(vault_, before), "settles at this close");
        assertFalse(policy.isClosed(vault_, after_), "waits for the next close");
    }

    /// @dev A window's key is its index, from which its close (`index * window + offset`) and each side's cutoff (the
    ///      close less the notice, less one) follow: a request at the cutoff still lands in the window, one a second
    ///      later in the next.
    function testAWindowsCloseAndCutoffFollowFromItsKey() public {
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, 20, 30, 150);
        address vault_ = _noticeVault();

        vm.warp(1_000_089);
        assertEq(
            uint256(_request(policy, vault_, true)), 10_001, "the deposit cutoff of the window closing at 1_000_120"
        );
        vm.warp(1_000_090);
        assertEq(uint256(_request(policy, vault_, true)), 10_002, "a second later");

        vm.warp(1_000_069);
        assertEq(
            uint256(_request(policy, vault_, false)), 10_002, "the redeem cutoff of the window closing at 1_000_220"
        );
        vm.warp(1_000_070);
        assertEq(uint256(_request(policy, vault_, false)), 10_003, "a second later");
    }

    function testNoticeIsSetAtConstruction() public {
        vm.expectEmit(vm.computeCreateAddress(address(this), vm.getNonce(address(this))));
        emit IPerPeriodPolicy.PerPeriodConfigured(WINDOW, 0, 30, 150);
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, 0, 30, 150);

        assertEq(policy.depositNotice(), 30);
        assertEq(policy.redeemNotice(), 150);
    }

    /// @dev Every open bucket takes a slot of a controller's horizon, so a vault refuses a horizon that cannot hold the
    ///      windows a notice spans and the open one, and its default is exactly that.
    function testTheHorizonCoversTheWindowsANoticeSpans() public {
        address policy = address(new PerPeriodPolicy(WINDOW, 0, 0, 4 * WINDOW));

        vm.expectRevert(IVaultErrors.InvalidFoldHorizon.selector);
        _vaultWith(policy, 4);

        assertEq(_vaultWith(policy, 5).foldHorizon(), 5, "the open window and the four the notice spans");
        assertEq(_vaultWith(policy, 0).foldHorizon(), 5, "the default holds them");
    }

    /// @dev A controller requesting in every window, at the smallest horizon the vault accepts, only ever evicts a window
    ///      that has closed: the open ones always fit.
    function testAnOwnRequestNeverEvictsAnOpenWindow() public {
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, 0, 4 * WINDOW, 0);
        vault = _vaultWith(address(policy), policy.maxOpenBuckets());
        requestPolicy = policy;

        uint96[] memory ids = new uint96[](12);
        uint256 evictions;
        for (uint256 i; i < ids.length; i++) {
            vm.warp(BASE_TS + i * WINDOW);
            vm.recordLogs();
            _requestDeposit(alice, 1e6);
            ids[i] = _depositLocalId();

            Vm.Log[] memory logs = vm.getRecordedLogs();
            for (uint256 l; l < logs.length; l++) {
                if (logs[l].topics[0] != IVaultEvents.OutsideHorizon.selector) continue;
                evictions++;
                for (uint256 j; j < i; j++) {
                    if (_reqId(ids[j]) != uint256(logs[l].topics[1])) continue;
                    assertTrue(
                        policy.isClosed(address(vault), IAsyncVault(address(vault)).keyOf(ids[j])),
                        "an open window was evicted"
                    );
                }
            }
        }
        assertGt(evictions, 0, "the horizon filled");
    }

    /// @dev A gift never takes a slot kept for the controller's open windows, so the next own request has room for
    ///      its open window without evicting another (lemunozm's case on #573).
    function testAGiftLeavesRoomForTheOpenWindows() public {
        PerPeriodPolicy policy = new PerPeriodPolicy(WINDOW, 0, WINDOW / 2, 0);
        assertEq(policy.maxOpenBuckets(), 2);
        vault = _vaultWith(address(policy), 2);
        requestPolicy = policy;

        // bob's request lands in window W, alice's own one in W + 1
        vm.warp(BASE_TS + 10);
        _requestDeposit(bob, 1e6);
        uint96 gift = _depositLocalId();
        vm.warp(BASE_TS + 60);
        _requestDeposit(alice, 1e6);
        uint96 own = _depositLocalId();

        // bob gives his W position to alice: the one free slot is kept for her other open window
        vm.expectEmit(address(vault));
        emit IVaultEvents.OutsideHorizon(_reqId(gift), alice, true);
        vm.prank(bob);
        IERC8161DepositTransferable(address(vault)).transferDepositRequest(_reqId(gift), bob, alice);

        // alice's next own request, into W + 2 while W + 1 is open, evicts nothing
        vm.warp(BASE_TS + 160);
        assertFalse(policy.isClosed(address(vault), IAsyncVault(address(vault)).keyOf(own)), "W + 1 still open");
        vm.recordLogs();
        _requestDeposit(alice, 1e6);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(logs[i].topics[0] != IVaultEvents.OutsideHorizon.selector, "nothing evicted");
        }

        // W + 1 settles and her claim sees it with no keeper
        vm.warp(BASE_TS + 200);
        IAsyncVault(address(vault)).flushRequest(own);
        _fulfillDeposit(own, 1e6, 1e18);
        assertEq(_maxMint(alice), 1e18, "claimable without foldRequest");
    }

    /// @dev Three live buckets on one side is the first count that spills past the two inline slots. Only the
    ///      horizon's entries count as claimable before a fold, so a third entry lost on write shows as a short claim.
    function testThreeLiveBucketsOnOneSideAreAllClaimable() public {
        _setHorizon(3);
        uint96[3] memory ids;
        for (uint256 i; i < 3; i++) {
            vm.warp(BASE_TS + i * WINDOW);
            _requestDeposit(alice, 1e6);
            ids[i] = _depositLocalId();
        }
        assertTrue(ids[0] != ids[1] && ids[1] != ids[2], "three distinct buckets");

        vm.warp(BASE_TS + 3 * WINDOW);
        for (uint256 i; i < 3; i++) {
            if (IAsyncVault(address(vault)).bucket(ids[i]).queued != 0) {
                IAsyncVault(address(vault)).flushRequest(ids[i]);
            }
            _fulfillDeposit(ids[i], 1e6, 1e18);
        }

        assertEq(IAsyncVault(address(vault)).claimableMint(alice), 3e18, "all three entries stay in the horizon");
    }

    //----------------------------------------------------------------------------------------------
    // Horizon, through the vault
    //----------------------------------------------------------------------------------------------

    function testHorizonFollowsTheConfig() public {
        _setHorizon(3);
        uint96[] memory ids = _openWindows(alice, 3);
        _settleWindows(ids);

        assertEq(_maxMint(alice), 3e18);
        vm.prank(alice);
        assertEq(IAsyncVault(address(vault)).deposit(3e6, alice, alice), 3e18);
    }

    /// @dev A new own position pushes the oldest out of the horizon, folding it first if it has settled.
    function testEvictionFoldsASettledPosition() public {
        _setHorizon(1);
        uint96[] memory ids = _openWindows(alice, 1);
        _settleWindows(ids);

        vm.warp(block.timestamp + WINDOW);
        _requestDeposit(alice, 1e6);

        assertEq(_maxMint(alice), 1e18, "folded on eviction");
        assertEq(_pending(0, alice), 1e6, "the new one");
    }

    /// @dev A full horizon makes way by its oldest position, which waits for a fold once it settles.
    function testAFullHorizonMakesWayByItsOldestPosition() public {
        _setHorizon(1);
        uint96[] memory ids = _openWindows(alice, 2);
        _settleWindows(ids);

        assertEq(_maxMint(alice), 1e18, "only the newest is in the horizon");
        assertEq(_pending(0, alice), 1e6, "the oldest waits");
        IAsyncVault(address(vault)).foldRequest(ids[0], alice);
        assertEq(_maxMint(alice), 2e18);
    }

    //----------------------------------------------------------------------------------------------
    // What the vault asks of a policy's answer
    //----------------------------------------------------------------------------------------------

    /// @dev The zero address marks a batch as the owner of a bucket, so it cannot be a controller.
    function testNoRequestNamesTheZeroController() public {
        vm.prank(alice);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        IAsyncVault(address(vault)).requestDeposit(1e6, address(0), alice);
    }

    function testNoRequestTransfersToTheZeroController() public {
        _requestDeposit(alice, 1e6);
        uint256 requestId = _reqId(_depositLocalId());

        vm.prank(alice);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        IERC8161DepositTransferable(address(vault)).transferDepositRequest(requestId, alice, address(0));
    }

    /// @dev The horizon is fixed at deployment, so a test that needs another starts on a fresh vault.
    function _setHorizon(uint256 horizon) internal {
        vault = _vaultWith(address(requestPolicy), horizon);
    }

    /// @dev One request of 1e6 for `who` in each of `n` consecutive windows, each its own bucket.
    function _openWindows(address who, uint256 n) internal returns (uint96[] memory ids) {
        ids = new uint96[](n);
        for (uint256 i; i < n; i++) {
            vm.warp(block.timestamp + WINDOW);
            _requestDeposit(who, 1e6);
            ids[i] = _depositLocalId();
        }
    }

    /// @dev Closes the last window, sends every bucket and fulfills each for 1e6 assets and 1e18 shares.
    function _settleWindows(uint96[] memory ids) internal {
        vm.warp(block.timestamp + WINDOW);
        for (uint256 i; i < ids.length; i++) {
            if (IAsyncVault(address(vault)).bucket(ids[i]).queued != 0) {
                IAsyncVault(address(vault)).flushRequest(ids[i]);
            }
            _fulfillDeposit(ids[i], 1e6, 1e18);
        }
    }

    function _vaultWith(address policy) internal returns (Vault) {
        return _vaultWith(policy, 0);
    }

    function _vaultWith(address policy, uint256 horizon) internal returns (Vault) {
        VaultConfig memory config = VaultConfig({
            foldHorizon: horizon,
            spoke: ISpoke(spoke),
            spokeRegistry: ISpokeRegistry(spokeRegistry),
            plugins: VaultPlugins({
                oracle: IVaultOracle(oracle),
                instantPolicy: IInstantPolicy(instantPolicy),
                requestPolicy: IRequestPolicy(policy),
                liquidityRoute: ILiquidityRoute(address(0)),
                settlementObserver: ISettlementObserver(address(0))
            })
        });
        return new Vault(POOL, SC, address(asset), ASSET_ID, IShareToken(address(share)), config);
    }
}
