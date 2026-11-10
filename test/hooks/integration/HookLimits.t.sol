// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20} from "../../../src/misc/interfaces/IERC20.sol";

import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";

import {IAsyncVault} from "../../../src/vaults/interfaces/IAsyncVault.sol";

import {CappedShareTokenHook} from "../mocks/CappedShareTokenHook.sol";

import {EndToEndFlows} from "../../integration/EndToEnd.t.sol";
import {HookData} from "../../../src/token/interfaces/ITransferHook.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {IntegrationConstants} from "../../integration/utils/IntegrationConstants.sol";

/// @dev ERC-4626 `max*` on the instant lane under a hook that limits amounts: the view never reports more than a call
///      can do. A hook that reports how much it allows (`maxAllowed`) gets its room reported; one that reports no
///      limit is asked at the vault's own capacity, and the view reports none where that is refused.
/// forge-config: default.isolate = true
contract HookLimitsTest is EndToEndFlows {
    IAsyncVault vault;
    IShareToken share;
    ShareTokenHook baseHook;

    function _setUpInstantVault() internal {
        _configurePool(true);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        vault = _deployInstantVault();
        lastInstantVault = address(vault);
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 0, address(0));
        share = IShareToken(vault.share());
        baseHook = ShareTokenHook(share.hook());

        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );
        s.usdc.mint(INVESTOR_A, USDC_AMOUNT_1 * 10);
        vm.prank(INVESTOR_A);
        s.usdc.approve(address(vault), type(uint256).max);
    }

    function _useHook(address hook) internal {
        vm.startPrank(FM);
        _setHook(s, hook);
        vm.stopPrank();
    }

    function testMaxDepositIsTheRoomAReportingHookAllows() public {
        _setUpInstantVault();
        uint256 capacity = vault.maxDeposit(INVESTOR_A);
        uint256 entryCap = vault.convertToShares(capacity) / 4;
        _useHook(address(new CappedShareTokenHook(baseHook, entryCap, type(uint256).max, true)));

        uint256 max = vault.maxDeposit(INVESTOR_A);
        assertGt(max, 0, "the room is reported");
        assertLt(max, capacity, "and it is below the lane's capacity");
        assertLe(vault.convertToShares(max), entryCap, "within the cap");

        vm.startPrank(INVESTOR_A);
        vault.deposit(max, INVESTOR_A);
        assertEq(vault.maxDeposit(INVESTOR_A), 0, "the room is used up");
        uint256 oneShare = vault.convertToAssets(1e18);
        vm.expectRevert();
        vault.deposit(oneShare, INVESTOR_A);
        vm.stopPrank();
    }

    function testMaxDepositNeverOverReportsForAHookThatDoesNotReport() public {
        _setUpInstantVault();
        uint256 capacity = vault.maxDeposit(INVESTOR_A);
        uint256 entryCap = vault.convertToShares(capacity) / 4;
        _useHook(address(new CappedShareTokenHook(baseHook, entryCap, type(uint256).max, false)));

        // Asked at the full capacity, the hook refuses, so the view reports none rather than too much
        assertEq(vault.maxDeposit(INVESTOR_A), 0);
        assertEq(vault.maxMint(INVESTOR_A), 0);

        // Below the cap a deposit still goes through
        vm.prank(INVESTOR_A);
        vault.deposit(capacity / 8, INVESTOR_A);
    }

    function testMaxDepositIsTheCapacityWhereTheHookAllowsAll() public {
        _setUpInstantVault();
        uint256 capacity = vault.maxDeposit(INVESTOR_A);
        _useHook(address(new CappedShareTokenHook(baseHook, type(uint256).max, type(uint256).max, false)));
        assertEq(vault.maxDeposit(INVESTOR_A), capacity);
    }

    function testMaxRedeemIsTheExitCapAReportingHookAllows() public {
        _setUpInstantVault();
        vm.prank(INVESTOR_A);
        uint256 shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        uint256 exitCap = shares / 3;
        _useHook(address(new CappedShareTokenHook(baseHook, type(uint256).max, exitCap, true)));

        uint256 maxRedeem = vault.maxRedeem(INVESTOR_A);
        assertGt(maxRedeem, 0, "the room is reported");
        assertLe(maxRedeem, exitCap, "within the cap");
        assertLe(vault.convertToShares(vault.maxWithdraw(INVESTOR_A)), exitCap, "withdraw within the cap");

        vm.startPrank(INVESTOR_A);
        vault.redeem(maxRedeem, INVESTOR_A);
        vm.expectRevert();
        vault.redeem(exitCap + 1, INVESTOR_A);
        vm.stopPrank();
    }

    function testMaxRedeemNeverOverReportsForAHookThatDoesNotReport() public {
        _setUpInstantVault();
        vm.prank(INVESTOR_A);
        uint256 shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        _useHook(address(new CappedShareTokenHook(baseHook, type(uint256).max, shares / 3, false)));

        assertEq(vault.maxRedeem(INVESTOR_A), 0);
        assertEq(vault.maxWithdraw(INVESTOR_A), 0);
        vm.prank(INVESTOR_A);
        vault.redeem(shares / 4, INVESTOR_A);
    }

    /// @dev A holder's transfer reaches the hook only as a transfer, so a position cap holds there too, while the
    ///      vault action that issued the shares was counted once, on its role check.
    function testAPositionCapHoldsOnATransferToo() public {
        _setUpInstantVault();
        vm.prank(INVESTOR_A);
        uint256 shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        uint256 cap = shares / 2;
        _useHook(address(new CappedShareTokenHook(baseHook, cap, type(uint256).max, true)));

        address holder = makeAddr("holder");
        vm.startPrank(INVESTOR_A);
        share.transfer(holder, cap);
        vm.expectRevert();
        share.transfer(holder, 1);
        vm.stopPrank();

        // At the cap, the holder is offered no instant deposit either
        assertEq(vault.maxDeposit(holder), 0);
    }

    /// @dev A cross-chain receipt is not capped: the source burned the shares, so a refusal would trap them, while the
    ///      same transfer from a holder is.
    function testACrossChainReceiptIsNotCapped() public {
        _setUpInstantVault();
        CappedShareTokenHook capped = new CappedShareTokenHook(baseHook, 1, type(uint256).max, true);
        address holder = makeAddr("holder");
        vm.mockCall(address(share), abi.encodeWithSelector(IERC20.balanceOf.selector, holder), abi.encode(uint256(1)));

        vm.startPrank(address(share));
        assertTrue(capped.checkERC20Transfer(capped.crosschainSource(), holder, 1, HookData(bytes16(0), bytes16(0))));
        assertFalse(capped.checkERC20Transfer(INVESTOR_A, holder, 1, HookData(bytes16(0), bytes16(0))));
        vm.stopPrank();
    }

    /// @dev With a spread on top, the reported deposit still issues the hook's whole room, not the room less the fee.
    function testMaxMintReachesTheRoomUnderASpread() public {
        _setUpInstantVault();
        _configureInstantLane(USDC_AMOUNT_1 * 10, 100, 0, makeAddr("feeRecipient"));
        uint256 room = vault.maxMint(INVESTOR_A) / 4;
        _useHook(address(new CappedShareTokenHook(baseHook, room, type(uint256).max, true)));

        uint256 maxMint = vault.maxMint(INVESTOR_A);
        assertLe(maxMint, room, "within the room");
        assertGe(maxMint, room - room / 1e6, "and all of it, to rounding");

        uint256 maxDeposit = vault.maxDeposit(INVESTOR_A);
        vm.prank(INVESTOR_A);
        uint256 shares = vault.deposit(maxDeposit, INVESTOR_A);
        assertLe(shares, room, "a deposit of maxDeposit stays within the room");
    }
}
