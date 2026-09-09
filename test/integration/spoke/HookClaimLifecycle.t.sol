// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {AsyncVault, VaultBaseTest as BaseTest} from "../vaults/VaultBaseTest.sol";

import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";

/// @title  HookClaimLifecycleTest
/// @notice A request is approved against the holder's membership at the moment it is made. By the time
///         the claim is available the holder has already paid: the assets are in the escrow, or the
///         shares are burned, or both are committed to a cancellation. Whether the tail of that flow is
///         gated again on membership is a decision each hook makes, and getting it wrong strands value
///         that no ordinary path can recover.
///
/// @dev    Two bugs of exactly this shape were fixed on this branch, one on the burn leg and one on the
///         escrow-to-holder leg, both in FreelyTransferable. This pins the answer for all four hooks and
///         all four claim legs, so the next one fails a test rather than reaching a release.
contract HookClaimLifecycleTest is BaseTest {
    using CastLib for *;

    uint128 constant AMOUNT = 100e6;

    struct Expected {
        bool depositClaim; // shares out of the escrow
        bool redeemClaim; // assets out, shares already burned
        bool cancelDepositRefund; // assets back, nothing burned
        bool cancelRedeemRefund; // shares back out of the escrow
    }

    function testFreezeOnly() public {
        _runAll(address(freezeOnlyHook), Expected(true, true, true, true));
    }

    function testRedemptionRestrictions() public {
        _runAll(address(redemptionRestrictionsHook), Expected(true, true, true, true));
    }

    /// @dev FullRestrictions gates receipt and not merely entry, so it withholds the two legs that hand a
    ///      holder shares. That is the compliance model rather than a defect: a non-member is not meant to
    ///      hold shares at all. The legs that pay out assets stay open, since the shares are already burned.
    function testFullRestrictions() public {
        _runAll(address(fullRestrictionsHook), Expected(false, true, true, false));
    }

    /// @dev FreelyTransferable withholds ALL FOUR, which is stricter than FullRestrictions on the two
    ///      asset-paying legs and contradicts its own docstring, since it promises membership only before
    ///      submitting a request. A holder whose validUntil lapses between request and claim is left with
    ///      neither the assets nor the shares until the pool re-adds them to the memberlist.
    ///
    ///      This is pinned as-is deliberately. The behaviour is byte-identical to v3.1.0 - both branches
    ///      and both hook query pairs are unchanged since then - so it is long-standing rather than a v3.3
    ///      regression, and correcting it changes the semantics of a shipped hook for live pools. That
    ///      belongs in its own change with its own review, not in a fix for a v3.3 regression. Pools
    ///      granting an unbounded validUntil never reach it.
    ///
    ///      All four are pinned as self-claims, which is not the whole story: see the test below.
    function testFreelyTransferable() public {
        _runAll(address(freelyTransferableHook), Expected(false, false, false, false));
    }

    /// @dev The four legs above are pinned as self-claims, controller == receiver, which is the shape the
    ///      views report. Two of them check only the receiver, so an expired holder still settles those by
    ///      naming a member; the two that hand out shares check the controller as well and stay closed to
    ///      any receiver. Pinned so hooks/README.md's per-entry-point account cannot drift from the code.
    function testFreelyTransferableExpiredHolderSettlesToAMember() public {
        Ctx memory c = _setUp(address(freelyTransferableHook), bytes16(bytes("5")), "withdrawer");
        _requestAndFulfilDeposit(c);
        vm.startPrank(c.investor);
        c.vault.mint(AMOUNT, c.investor, c.investor);
        c.vault.requestRedeem(AMOUNT, c.investor, c.investor);
        vm.stopPrank();
        centrifugeChain.isFulfilledRedeemRequest(
            c.poolId, c.scId, bytes32(bytes20(c.investor)), c.assetId, AMOUNT, AMOUNT, 0
        );
        _lapse(c);
        address assetReceiver = _member(c, "assetReceiver");

        // `redeem` gates on maxRedeem and so checks the controller; `withdraw` carries no such gate
        assertEq(c.vault.maxWithdraw(c.investor), 0, "the self-claim view reads zero");
        vm.prank(c.investor);
        c.vault.withdraw(AMOUNT, assetReceiver, c.investor);
        assertEq(erc20.balanceOf(assetReceiver), AMOUNT, "withdraw to a member receiver was withheld");

        Ctx memory d = _setUp(address(freelyTransferableHook), bytes16(bytes("6")), "refunder");
        erc20.mint(d.investor, AMOUNT);
        vm.startPrank(d.investor);
        erc20.approve(address(d.vault), AMOUNT);
        d.vault.requestDeposit(AMOUNT, d.investor, d.investor);
        d.vault.cancelDepositRequest(0, d.investor);
        vm.stopPrank();
        centrifugeChain.isFulfilledDepositRequest(
            d.poolId, d.scId, bytes32(bytes20(d.investor)), d.assetId, 0, 0, AMOUNT
        );
        _lapse(d);
        address refundReceiver = _member(d, "refundReceiver");

        assertEq(d.vault.claimableCancelDepositRequest(0, d.investor), 0, "the self-claim view reads zero");
        vm.prank(d.investor);
        d.vault.claimCancelDepositRequest(0, refundReceiver, d.investor);
        assertEq(erc20.balanceOf(refundReceiver), AMOUNT, "cancelled deposit refund to a member was withheld");

        Ctx memory e = _setUp(address(freelyTransferableHook), bytes16(bytes("7")), "shareClaimer");
        _requestAndFulfilDeposit(e);
        _lapse(e);
        address shareReceiver = _member(e, "shareReceiver");

        // The share-paying legs check the controller too, so naming a member buys nothing
        vm.prank(e.investor);
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        e.vault.mint(AMOUNT, shareReceiver, e.investor);
    }

    function _runAll(address hook, Expected memory e) internal {
        _depositClaim(hook, bytes16(bytes("1")), e.depositClaim);
        _redeemClaim(hook, bytes16(bytes("2")), e.redeemClaim);
        _cancelDepositRefund(hook, bytes16(bytes("3")), e.cancelDepositRefund);
        _cancelRedeemRefund(hook, bytes16(bytes("4")), e.cancelRedeemRefund);
    }

    struct Ctx {
        AsyncVault vault;
        uint128 assetId;
        address investor;
        uint64 poolId;
        bytes16 scId;
    }

    /// @dev A member up to the point the request is made, and no longer one when the claim arrives.
    function _setUp(address hook, bytes16 scId, string memory who) internal returns (Ctx memory c) {
        (, address vault_, uint128 assetId) = deployVault(asyncVaultFactory, 6, hook, scId, address(erc20), 0);
        c.vault = AsyncVault(vault_);
        c.assetId = assetId;
        c.investor = makeAddr(who);
        c.poolId = c.vault.poolId().raw();
        c.scId = c.vault.scId().raw();

        centrifugeChain.updatePricePoolPerShare(c.poolId, c.scId, defaultPrice, uint64(block.timestamp));
        centrifugeChain.updateMember(c.poolId, c.scId, c.investor, uint64(block.timestamp + 7 days));
    }

    function _lapse(Ctx memory c) internal {
        vm.warp(block.timestamp + 8 days);
        centrifugeChain.updatePricePoolPerShare(c.poolId, c.scId, defaultPrice, uint64(block.timestamp));
    }

    function _member(Ctx memory c, string memory who) internal returns (address member) {
        member = makeAddr(who);
        centrifugeChain.updateMember(c.poolId, c.scId, member, uint64(block.timestamp + 7 days));
    }

    function _requestAndFulfilDeposit(Ctx memory c) internal {
        erc20.mint(c.investor, AMOUNT);
        vm.startPrank(c.investor);
        erc20.approve(address(c.vault), AMOUNT);
        c.vault.requestDeposit(AMOUNT, c.investor, c.investor);
        vm.stopPrank();
        centrifugeChain.isFulfilledDepositRequest(
            c.poolId, c.scId, bytes32(bytes20(c.investor)), c.assetId, AMOUNT, AMOUNT, 0
        );
    }

    function _depositClaim(address hook, bytes16 scId, bool expected) internal {
        Ctx memory c = _setUp(hook, scId, "depositClaimer");
        _requestAndFulfilDeposit(c);
        assertEq(erc20.balanceOf(c.investor), 0, "assets already paid in");
        _lapse(c);

        if (expected) {
            assertEq(c.vault.maxMint(c.investor), AMOUNT, "deposit claim withheld after membership lapsed");
            vm.prank(c.investor);
            c.vault.mint(AMOUNT, c.investor, c.investor);
            assertEq(IShareToken(address(c.vault.share())).balanceOf(c.investor), AMOUNT, "shares not delivered");
        } else {
            assertEq(c.vault.maxMint(c.investor), 0, "deposit claim allowed to a non-member");
        }
    }

    function _redeemClaim(address hook, bytes16 scId, bool expected) internal {
        Ctx memory c = _setUp(hook, scId, "redeemClaimer");
        _requestAndFulfilDeposit(c);
        vm.startPrank(c.investor);
        c.vault.mint(AMOUNT, c.investor, c.investor);
        c.vault.requestRedeem(AMOUNT, c.investor, c.investor);
        vm.stopPrank();
        centrifugeChain.isFulfilledRedeemRequest(
            c.poolId, c.scId, bytes32(bytes20(c.investor)), c.assetId, AMOUNT, AMOUNT, 0
        );
        assertEq(IShareToken(address(c.vault.share())).balanceOf(c.investor), 0, "shares already burned");
        _lapse(c);

        if (expected) {
            assertEq(c.vault.maxRedeem(c.investor), AMOUNT, "redeem claim withheld after membership lapsed");
            vm.prank(c.investor);
            c.vault.redeem(AMOUNT, c.investor, c.investor);
            assertEq(erc20.balanceOf(c.investor), AMOUNT, "assets not delivered");
        } else {
            assertEq(c.vault.maxRedeem(c.investor), 0, "redeem claim allowed to a non-member");
        }
    }

    function _cancelDepositRefund(address hook, bytes16 scId, bool expected) internal {
        Ctx memory c = _setUp(hook, scId, "depositCanceller");
        erc20.mint(c.investor, AMOUNT);
        vm.startPrank(c.investor);
        erc20.approve(address(c.vault), AMOUNT);
        c.vault.requestDeposit(AMOUNT, c.investor, c.investor);
        c.vault.cancelDepositRequest(0, c.investor);
        vm.stopPrank();
        centrifugeChain.isFulfilledDepositRequest(
            c.poolId, c.scId, bytes32(bytes20(c.investor)), c.assetId, 0, 0, AMOUNT
        );
        _lapse(c);

        if (expected) {
            assertEq(
                c.vault.claimableCancelDepositRequest(0, c.investor),
                AMOUNT,
                "cancelled deposit withheld after membership lapsed"
            );
            vm.prank(c.investor);
            c.vault.claimCancelDepositRequest(0, c.investor, c.investor);
            assertEq(erc20.balanceOf(c.investor), AMOUNT, "assets not refunded");
        } else {
            assertEq(c.vault.claimableCancelDepositRequest(0, c.investor), 0, "refund allowed to a non-member");
        }
    }

    function _cancelRedeemRefund(address hook, bytes16 scId, bool expected) internal {
        Ctx memory c = _setUp(hook, scId, "redeemCanceller");
        _requestAndFulfilDeposit(c);
        vm.startPrank(c.investor);
        c.vault.mint(AMOUNT, c.investor, c.investor);
        c.vault.requestRedeem(AMOUNT, c.investor, c.investor);
        c.vault.cancelRedeemRequest(0, c.investor);
        vm.stopPrank();
        centrifugeChain.isFulfilledRedeemRequest(
            c.poolId, c.scId, bytes32(bytes20(c.investor)), c.assetId, 0, 0, AMOUNT
        );
        assertEq(IShareToken(address(c.vault.share())).balanceOf(c.investor), 0, "shares are in the escrow");
        _lapse(c);

        if (expected) {
            assertEq(
                c.vault.claimableCancelRedeemRequest(0, c.investor),
                AMOUNT,
                "cancelled redeem withheld after membership lapsed"
            );
            vm.prank(c.investor);
            c.vault.claimCancelRedeemRequest(0, c.investor, c.investor);
            assertEq(IShareToken(address(c.vault.share())).balanceOf(c.investor), AMOUNT, "shares not returned");
        } else {
            assertEq(c.vault.claimableCancelRedeemRequest(0, c.investor), 0, "refund allowed to a non-member");
        }
    }
}
