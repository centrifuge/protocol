// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {CastLib} from "src/vaults/libraries/CastLib.sol";
import {RestrictedRedemptions} from "src/vaults/token/RestrictedRedemptions.sol";

contract RedeemTest is BaseTest {
    using CastLib for *;

    function testRestrictedRedemptions(uint256 amount) public {
        amount = uint128(bound(amount, 2, MAX_UINT128 / 2));

        address vault_ = deployVault(
            5, 6, restrictedRedemptions, "name", "symbol", bytes16(bytes("1")), defaultAssetId, address(erc20)
        );
        ERC7540Vault vault = ERC7540Vault(vault_);
        RestrictedRedemptions hook = RestrictedRedemptions(restrictedRedemptions);
        ITranche tranche = ITranche(address(vault.share()));

        centrifugeChain.updateTranchePrice(
            vault.poolId(), vault.trancheId(), defaultAssetId, defaultPrice, uint64(block.timestamp)
        );

        // Anyone can deposit
        address investor = makeAddr("Investor");
        erc20.mint(investor, amount);

        vm.startPrank(investor);
        erc20.approve(vault_, amount);
        (bool isMember,) = hook.isMember(address(tranche), investor);
        assertEq(isMember, false);
        vault.requestDeposit(amount, investor, investor);
        vm.stopPrank();

        centrifugeChain.isFulfilledDepositRequest(
            vault.poolId(),
            vault.trancheId(),
            bytes32(bytes20(investor)),
            defaultAssetId,
            uint128(amount),
            uint128(amount)
        );

        vm.prank(investor);
        vault.deposit(amount, investor, investor);

        // Can transfer to anyone
        address investor2 = makeAddr("Investor2");
        vm.prank(investor);
        tranche.transfer(investor2, amount / 2);

        // Not everyone can redeem
        vm.expectRevert(bytes("InvestmentManager/transfer-not-allowed"));
        vm.prank(investor);
        vault.requestRedeem(amount / 2, investor, investor);

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), investor, type(uint64).max);
        (isMember,) = hook.isMember(address(tranche), investor);
        assertEq(isMember, true);

        vm.prank(investor);
        vault.requestRedeem(amount / 2, investor, investor);

        centrifugeChain.isFulfilledRedeemRequest(
            vault.poolId(),
            vault.trancheId(),
            bytes32(bytes20(investor)),
            defaultAssetId,
            uint128(amount / 2),
            uint128(amount / 2)
        );

        vm.prank(investor);
        vault.redeem(amount / 2, investor, investor);
    }
}
