// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import "../../spoke/integration/BaseTest.sol";

import {IAsyncRequestManager} from "../../../src/vaults/interfaces/IVaultManagers.sol";

import {FreelyTransferable} from "../../../src/hooks/FreelyTransferable.sol";

contract FreelyTransferableTest is BaseTest {
    using CastLib for *;

    function testFreelyTransferableHook(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        (, address vault_, uint128 assetId) =
            deployVault(VaultKind.Async, 6, address(freelyTransferableHook), bytes16(bytes("1")), address(erc20), 0, 0);
        AsyncVault vault = AsyncVault(vault_);
        FreelyTransferable hook = FreelyTransferable(freelyTransferableHook);
        IShareToken shareToken = IShareToken(address(vault.share()));

        centrifugeChain.updatePricePoolPerShare(
            vault.poolId().raw(), vault.scId().raw(), defaultPrice, uint64(block.timestamp)
        );

        // Only members can deposit
        address investor = makeAddr("Investor");
        erc20.mint(investor, amount);

        vm.startPrank(investor);
        erc20.approve(vault_, amount);

        (bool isMember,) = hook.isMember(address(shareToken), investor);
        assertEq(isMember, false);

        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vault.requestDeposit(amount, investor, investor);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor, type(uint64).max);

        (isMember,) = hook.isMember(address(shareToken), investor);
        assertEq(isMember, true);

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

        // Not everyone can redeem
        vm.expectRevert(IAsyncRequestManager.TransferNotAllowed.selector);
        vm.prank(investor2);
        vault.requestRedeem(amount / 2, investor2, investor2);

        centrifugeChain.updateMember(vault.poolId().raw(), vault.scId().raw(), investor2, type(uint64).max);
        (isMember,) = hook.isMember(address(shareToken), investor2);
        assertEq(isMember, true);

        vm.prank(investor2);
        vault.requestRedeem(amount / 2, investor2, investor2);
        uint128 fulfillment = uint128(amount / 2);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId().raw(), vault.scId().raw(), bytes32(bytes20(investor2)), assetId, fulfillment, fulfillment, 0
        );

        vm.prank(investor2);
        vault.redeem(amount / 2, investor2, investor2);
    }
}
