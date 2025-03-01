// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "test/vaults/BaseTest.sol";
import {InstantDepositVault} from "src/vaults/InstantDepositVault.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IInstantManager} from "src/vaults/interfaces/IInstantManager.sol";

contract DepositTest is BaseTest {
    using CastLib for *;

    function testInstantDeposit(uint256 amount) public {
        // If lower than 4 or odd, rounding down can lead to not receiving any tokens
        amount = uint128(bound(amount, 4, MAX_UINT128));
        vm.assume(amount % 2 == 0);

        uint128 price = 2 * 10 ** 18;

        // Deploy async vault to ensure pool is set up
        address asyncVault_ = deploySimpleVault();
        ERC7540Vault asyncVault = ERC7540Vault(asyncVault_);
        ITranche tranche = ITranche(address(asyncVault.share()));
        centrifugeChain.updateTranchePrice(
            asyncVault.poolId(), asyncVault.trancheId(), defaultAssetId, price, uint64(block.timestamp)
        );

        erc20.mint(self, amount);

        // Deploy instant vault
        // TOOD: section should be replaced by new instant deposit vault deployment in pool mgr
        InstantDepositVault vault = new InstantDepositVault(
            asyncVault.poolId(),
            asyncVault.trancheId(),
            asyncVault.asset(),
            asyncVault.share(),
            address(root),
            address(investmentManager),
            address(instantManager)
        );
        root.relyContract(address(tranche), address(instantManager));
        root.relyContract(address(tranche), address(vault));
        root.relyContract(address(investmentManager), address(vault));

        // Check price and max amounts
        assertEq(vault.previewMint(amount / 2), amount);
        assertEq(vault.previewDeposit(amount), amount / 2);
        assertEq(vault.maxDeposit(self), type(uint256).max);
        assertEq(vault.maxMint(self), type(uint256).max);

        // Will fail - user did not give asset allowance to vault
        vm.expectRevert(SafeTransferLib.SafeTransferFromFailed.selector);
        vault.deposit(amount, self);
        erc20.approve(address(vault), amount);

        // Will fail - user not member: can not send funds
        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        vault.deposit(amount, self);

        assertEq(vault.isPermissioned(self), false);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), self, type(uint64).max); // add user as member
        assertEq(vault.isPermissioned(self), true);

        // Will fail - investment asset not allowed
        centrifugeChain.disallowAsset(vault.poolId(), defaultAssetId);
        vm.expectRevert(IInstantManager.AssetNotAllowed.selector);
        vault.deposit(amount, self);

        assertEq(tranche.balanceOf(self), 0);
        assertEq(erc20.balanceOf(self), amount);

        // Success
        centrifugeChain.allowAsset(vault.poolId(), defaultAssetId);
        vault.deposit(amount, self);

        assertEq(erc20.balanceOf(self), 0);
        assertEq(tranche.balanceOf(self), amount / 2);

        // Can now request redemption through async vault
        // TODO: doesn't work yet becuase investments in investment mgr are indexed by the async vault address
        // assertEq(asyncVault.pendingRedeemRequest(0, self), 0);
        // vault.requestRedeem(amount / 2, self, self);

        // assertEq(asyncVault.pendingRedeemRequest(0, self), amount / 2);
    }
}
