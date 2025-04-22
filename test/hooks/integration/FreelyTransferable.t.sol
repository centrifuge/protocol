// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {FreelyTransferable} from "src/hooks/FreelyTransferable.sol";
import {IAsyncRequests} from "src/vaults/interfaces/investments/IAsyncRequests.sol";

contract RedeemTest is BaseTest {
    using CastLib for *;

    function testFreelyTransferable(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (, address vault_, uint128 assetId) =
            deployVault(VaultKind.Async, 6, freelyTransferable, bytes16(bytes("1")), address(erc20), 0, 0);
        AsyncVault vault = AsyncVault(vault_);
        FreelyTransferable hook = FreelyTransferable(freelyTransferable);
        IShareToken shareToken = IShareToken(address(vault.share()));

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId(), vault.scId(), defaultPrice, uint64(block.timestamp)
        );

        // Anyone can deposit
        address investor = makeAddr("Investor");
        erc20.mint(investor, amount);

        vm.startPrank(investor);
        erc20.approve(vault_, amount);
        (bool isMember,) = hook.isMember(address(shareToken), investor);
        assertEq(isMember, false);
        vault.requestDeposit(amount, investor, investor);
        vm.stopPrank();

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(), vault.scId(), bytes32(bytes20(investor)), assetId, uint128(amount), uint128(amount)
        );

        vm.prank(investor);
        vault.deposit(amount, investor, investor);

        // Can transfer to anyone
        address investor2 = makeAddr("Investor2");
        vm.prank(investor);
        shareToken.transfer(investor2, amount / 2);

        // Not everyone can redeem
        vm.expectRevert(IAsyncRequests.TransferNotAllowed.selector);
        vm.prank(investor);
        vault.requestRedeem(amount / 2, investor, investor);

        centrifugeChain.updateMember(vault.poolId(), vault.scId(), investor, type(uint64).max);
        (isMember,) = hook.isMember(address(shareToken), investor);
        assertEq(isMember, true);

        vm.prank(investor);
        vault.requestRedeem(amount / 2, investor, investor);
        uint128 fulfillment = uint128(amount / 2);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId(), vault.scId(), bytes32(bytes20(investor)), assetId, fulfillment, fulfillment
        );

        vm.prank(investor);
        vault.redeem(amount / 2, investor, investor);
    }
}
