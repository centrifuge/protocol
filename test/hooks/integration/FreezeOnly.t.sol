// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {ITransferHook} from "../../../src/common/interfaces/ITransferHook.sol";

import "../../spoke/integration/BaseTest.sol";

contract FreezeOnlyTest is BaseTest {
    using CastLib for *;

    function testFreezeOnlyHook(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (, address vault_, uint128 assetId) =
            deployVault(VaultKind.Async, 6, address(freezeOnlyHook), bytes16(bytes("1")), address(erc20), 0, 0);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(vault.share()));

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), defaultPrice, uint64(block.timestamp)
        );

        // Anyone can deposit
        address investor = makeAddr("Investor");
        erc20.mint(investor, amount);

        vm.startPrank(investor);
        erc20.approve(vault_, amount);

        vault.requestDeposit(amount, investor, investor);
        vm.stopPrank();

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId().raw(),
            vault.scId().raw(),
            bytes32(bytes20(investor)),
            assetId,
            uint128(amount),
            uint128(amount),
            0
        );

        vm.prank(investor);
        vault.deposit(amount, investor, investor);

        // Can transfer to anyone
        address investor2 = makeAddr("Investor2");
        vm.prank(investor);
        shareToken.transfer(investor2, amount / 2);

        // Anyone can redeem
        vm.prank(investor2);
        vault.requestRedeem(amount / 2, investor2, investor2);
        uint128 fulfillment = uint128(amount / 2);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(investor2)), assetId, fulfillment, fulfillment, 0
        );

        vm.prank(investor2);
        vault.redeem(amount / 2, investor2, investor2);

        // Frozen users cannot transfer, deposit or redeem
        centrifugeChain.freeze(vault.poolId().raw(), vault.scId().raw(), investor);

        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vm.prank(investor);
        shareToken.transfer(investor2, amount / 2);
    }
}
