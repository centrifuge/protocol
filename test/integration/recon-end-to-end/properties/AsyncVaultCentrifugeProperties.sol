// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {vm} from "@chimera/Hevm.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {Setup} from "test/integration/recon-end-to-end/Setup.sol";
import {AsyncVaultProperties} from "test/integration/recon-end-to-end/properties/AsyncVaultProperties.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
/// @dev ERC-7540 Properties used by Centrifuge
/// See `AsyncVaultProperties` for more properties that can be re-used in your project
abstract contract AsyncVaultCentrifugeProperties is Setup, Asserts, AsyncVaultProperties {

    /// === Overridden Implementations === ///
    function asyncVault_3(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_3(asyncVaultTarget);
    }

    function asyncVault_4(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_4(asyncVaultTarget);
    }

    function asyncVault_5(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_5(asyncVaultTarget);
    }

    function asyncVault_6_deposit(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_deposit(asyncVaultTarget, amt);
    }

    function asyncVault_6_mint(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_mint(asyncVaultTarget, amt);
    }

    function asyncVault_6_withdraw(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_withdraw(asyncVaultTarget, amt);
    }

    function asyncVault_6_redeem(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_redeem(asyncVaultTarget, amt);
    }

    function asyncVault_7(address asyncVaultTarget, uint256 shares) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_7(asyncVaultTarget, shares);
    }

    function asyncVault_8(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_8(asyncVaultTarget);
    }

    function asyncVault_9_deposit(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_deposit(asyncVaultTarget);
    }

    function asyncVault_9_mint(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_mint(asyncVaultTarget);
    }

    function asyncVault_9_withdraw(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_withdraw(asyncVaultTarget);
    }

    function asyncVault_9_redeem(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_redeem(asyncVaultTarget);
    }


    /// === Custom Properties === ///

    /// @dev Property: user can always maxDeposit if they have > 0 assets and are approved
    /// @dev Property: user can always deposit an amount between 1 and maxDeposit have > 0 assets and are approved
    /// @dev Property: maxDeposit should decrease by the amount deposited
    function asyncVault_maxDeposit(uint64 poolEntropy, uint32 scEntropy, uint256 depositAmount) public  {
        uint256 maxDepositBefore = vault.maxDeposit(address(this));
        require(maxDepositBefore > 0, "must be able to deposit");

        depositAmount = between(depositAmount, 1, maxDepositBefore);

        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        (uint32 latestDepositApproval,,,) = shareClassManager.epochPointers(scId, assetId);
    
        vm.prank(_getActor());
        try vault.deposit(depositAmount, _getActor()) {
            uint256 maxDepositAfter = vault.maxDeposit(address(this));
            uint256 difference = maxDepositBefore - depositAmount;
            t(difference == maxDepositAfter, "rounding error in maxDeposit");
        }
        catch {
            t(latestDepositApproval < depositAmount, "reverts on deposit for approved amount");
        }
    }

    /// @dev user can always maxMint if they have > 0 assets and are approved
    /// @dev user can always mint an amount between 1 and maxMint have > 0 assets and are approved
    function asyncVault_maxMint(uint64 poolEntropy, uint32 scEntropy, uint256 mintAmount) public  {
        uint256 maxMintBefore = vault.maxMint(address(this));
        require(maxMintBefore > 0, "must be able to mint");

        mintAmount = between(mintAmount, 1, maxMintBefore);

        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        (uint32 latestDepositApproval,,,) = shareClassManager.epochPointers(scId, assetId);
    
        vm.prank(_getActor());
        try vault.mint(mintAmount, _getActor()) {
            uint256 maxMintAfter = vault.maxMint(address(this));
            uint256 difference = maxMintBefore - mintAmount;
            t(difference == maxMintAfter, "rounding error in maxMint");
        }
        catch {
            t(latestDepositApproval < mintAmount, "reverts on mint for approved amount");
        }
    }

    /// @dev user can always maxWithdraw if they have > 0 shares and are approved
    /// @dev user can always withdraw an amount between 1 and maxWithdraw have > 0 shares and are approved
    function asyncVault_maxWithdraw(uint64 poolEntropy, uint32 scEntropy, uint256 withdrawAmount) public  {
        uint256 maxWithdrawBefore = vault.maxWithdraw(address(this));
        require(maxWithdrawBefore > 0, "must be able to withdraw");

        withdrawAmount = between(withdrawAmount, 1, maxWithdrawBefore);

        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        (,uint32 latestRedeemApproval,,) = shareClassManager.epochPointers(scId, assetId);
    
        vm.prank(_getActor());
        try vault.withdraw(withdrawAmount, _getActor(), _getActor()) {
            uint256 maxWithdrawAfter = vault.maxWithdraw(address(this));
            uint256 difference = maxWithdrawBefore - withdrawAmount;
            t(difference == maxWithdrawAfter, "rounding error in maxWithdraw");
        }
        catch {
            t(latestRedeemApproval < withdrawAmount, "reverts on withdraw for approved amount");
        }
    }

    /// @dev user can always maxRedeem if they have > 0 shares and are approved
    /// @dev user can always redeem an amount between 1 and maxRedeem have > 0 shares and are approved
    function asyncVault_maxRedeem(uint64 poolEntropy, uint32 scEntropy, uint256 redeemAmount) public  {
        uint256 maxRedeemBefore = vault.maxRedeem(address(this));
        require(maxRedeemBefore > 0, "must be able to redeem");

        redeemAmount = between(redeemAmount, 1, maxRedeemBefore);

        PoolId poolId = Helpers.getRandomPoolId(createdPools, poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        (,uint32 latestRedeemApproval,,) = shareClassManager.epochPointers(scId, assetId);
    
        vm.prank(_getActor());
        try vault.redeem(redeemAmount, _getActor(), _getActor()) {
            uint256 maxRedeemAfter = vault.maxRedeem(address(this));
            uint256 difference = maxRedeemBefore - redeemAmount;
            t(difference == maxRedeemAfter, "rounding error in maxRedeem");
        }
        catch {
            t(latestRedeemApproval < redeemAmount, "reverts on redeem for approved amount");
        }
    }
    
    /// @dev Since we deploy and set addresses via handlers
    // We can have zero values initially
    // We have these checks to prevent false positives
    // This is tightly coupled to our system
    // A simpler system with no actors would not need these checks
    // Although they don't hurt
    // NOTE: We could also change the entire propertie to handlers and we would be ok as well
    function _canCheckProperties() internal view returns (bool) {
        if (TODO_RECON_SKIP_ERC7540) {
            return false;
        }
        if (address(vault) == address(0)) {
            return false;
        }
        if (address(token) == address(0)) {
            return false;
        }
        if (address(restrictedTransfers) == address(0)) {
            return false;
        }
        if (_getAsset() == address(0)) {
            return false;
        }

        return true;
    }

    function _centrifugeSpecificPreChecks() internal view {
        require(msg.sender == address(this)); // Enforces external call to ensure it's not state altering
        require(_canCheckProperties()); // Early revert to prevent false positives
    }
}
