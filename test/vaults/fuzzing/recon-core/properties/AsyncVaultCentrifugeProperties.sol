// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {vm} from "@chimera/Hevm.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {Setup} from "test/vaults/fuzzing/recon-core/Setup.sol";
import {AsyncVaultProperties} from "test/vaults/fuzzing/recon-core/properties/AsyncVaultProperties.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";
/// @dev ERC-7540 Properties used by Centrifuge
/// See `AsyncVaultProperties` for more properties that can be re-used in your project

abstract contract AsyncVaultCentrifugeProperties is Setup, Asserts, AsyncVaultProperties {
    using CastLib for *;

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

    /// @dev Property: depositing maxDeposit leaves a user with 0 orders
    /// @dev Property: depositing maxDeposit doesn't mint more than maxMint shares
    function asyncVault_maxDeposit(uint256 depositAmount) public {
        uint256 maxDepositBefore = vault.maxDeposit(_getActor());
        require(maxDepositBefore > 0, "must be able to deposit");

        depositAmount = between(depositAmount, 1, maxDepositBefore);

        (uint128 maxMint,,,,,,,,,) = asyncRequestManager.investments(IBaseVault(address(vault)), _getActor());

        vm.prank(_getActor());
        try vault.deposit(depositAmount, _getActor()) returns (uint256 shares) {
            uint256 maxDepositAfter = vault.maxDeposit(_getActor());
            uint256 difference = maxDepositBefore - depositAmount;

            t(difference == maxDepositAfter, "rounding error in maxDeposit");

            if (depositAmount == maxDepositBefore) {
                (,,,, uint128 pendingDeposit,,,,,) =
                    asyncRequestManager.investments(IBaseVault(address(vault)), _getActor());

                eq(pendingDeposit, 0, "pendingDeposit should be 0 after maxDeposit");
                lte(shares, maxMint, "shares minted surpass maxMint");
            }
        } catch {}
    }

    /// @dev Property: maxMint should be 0 after using maxMint as mintAmount
    /// @dev Property: minting maxMint should not mint more than maxDeposit shares
    function asyncVault_maxMint(uint256 mintAmount) public {
        uint256 maxMintBefore = vault.maxMint(_getActor());
        uint256 maxDepositBefore = vault.maxDeposit(_getActor());
        require(maxMintBefore > 0, "must be able to mint");

        mintAmount = between(mintAmount, 1, maxMintBefore);

        vm.prank(_getActor());
        try vault.mint(mintAmount, _getActor()) returns (uint256 assets) {
            uint256 maxMintAfter = vault.maxMint(_getActor());
            uint256 difference = maxMintBefore - mintAmount;
            t(difference == maxMintAfter, "rounding error in maxMint");
            uint256 shares = vault.convertToShares(assets);

            if (mintAmount == maxMintBefore) {
                (uint128 maxMint,,,,,,,,,) = asyncRequestManager.investments(IBaseVault(address(vault)), _getActor());
                uint256 maxMintVaultAfter = vault.maxMint(_getActor());

                eq(maxMint, 0, "maxMint in request should be 0 after maxMint");
                eq(maxMintVaultAfter, 0, "maxMint in vault should be 0 after maxMint");
                lte(shares, maxDepositBefore, "shares minted surpass maxMint");
            }
        } catch {}
    }

    /// @dev user can always maxWithdraw if they have > 0 shares and are approved
    /// @dev user can always withdraw an amount between 1 and maxWithdraw have > 0 shares and are approved
    function asyncVault_maxWithdraw(uint256 withdrawAmount) public {
        uint256 maxWithdrawBefore = vault.maxWithdraw(_getActor());
        require(maxWithdrawBefore > 0, "must be able to withdraw");

        withdrawAmount = between(withdrawAmount, 1, maxWithdrawBefore);

        vm.prank(_getActor());
        try vault.withdraw(withdrawAmount, _getActor(), _getActor()) returns (uint256 shares) {
            uint256 maxWithdrawAfter = vault.maxWithdraw(_getActor());
            uint256 difference = maxWithdrawBefore - withdrawAmount;
            uint256 assets = vault.convertToAssets(shares);

            t(difference == maxWithdrawAfter, "rounding error in maxWithdraw");

            if (withdrawAmount == maxWithdrawBefore) {
                (,,,,, uint128 pendingWithdrawRequest,,,,) =
                    asyncRequestManager.investments(IBaseVault(address(vault)), _getActor());

                eq(pendingWithdrawRequest, 0, "pendingWithdrawRequest should be 0 after maxWithdraw");
                lte(assets, maxWithdrawBefore, "shares withdrawn surpass maxWithdraw");
            }
        } catch {}
    }

    /// @dev user can always maxRedeem if they have > 0 shares and are approved
    /// @dev user can always redeem an amount between 1 and maxRedeem have > 0 shares and are approved
    /// @dev Property: redeeming maxRedeem leaves user with 0 pending redeem requests
    function asyncVault_maxRedeem(uint256 redeemAmount) public {
        uint256 maxRedeemBefore = vault.maxRedeem(_getActor());
        require(maxRedeemBefore > 0, "must be able to redeem");

        redeemAmount = between(redeemAmount, 1, maxRedeemBefore);

        vm.prank(_getActor());
        try vault.redeem(redeemAmount, _getActor(), _getActor()) returns (uint256 assets) {
            uint256 maxRedeemAfter = vault.maxRedeem(_getActor());
            uint256 difference = maxRedeemBefore - redeemAmount;
            uint256 shares = vault.convertToShares(assets);

            t(difference == maxRedeemAfter, "rounding error in maxRedeem");

            if (redeemAmount == maxRedeemBefore) {
                (,,,,, uint128 pendingRedeemRequest,,,,) =
                    asyncRequestManager.investments(IBaseVault(address(vault)), _getActor());

                eq(pendingRedeemRequest, 0, "pendingRedeemRequest should be 0 after maxRedeem");
                lte(shares, maxRedeemBefore, "shares redeemed surpass maxRedeem");
            }
        } catch {}
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
        if (address(fullRestrictions) == address(0)) {
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
