// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {Setup} from "test/integration/recon-end-to-end/Setup.sol";
import {AsyncVaultProperties} from "test/integration/recon-end-to-end/properties/AsyncVaultProperties.sol";
import {Helpers} from "test/hub/fuzzing/recon-hub/utils/Helpers.sol";

import {console2} from "forge-std/console2.sol";
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

    /// @dev Property: user can always maxDeposit if they have > 0 assets and are approved
    /// @dev Property: user can always deposit an amount between 1 and maxDeposit have > 0 assets and are approved
    /// @dev Property: maxDeposit should decrease by the amount deposited
    /// @dev Property: depositing maxDeposit leaves a user with 0 orders
    /// @dev Property: depositing maxDeposit doesn't mint more than maxMint shares
    // function asyncVault_maxDeposit(uint64 poolEntropy, uint32 scEntropy, uint256 depositAmount) public statelessTest {
    // NOTE: temporarily remove the statelessTest modifier to optimize the difference
    function asyncVault_maxDeposit(uint64 poolEntropy, uint32 scEntropy, uint256 depositAmount) public {
        uint256 maxDepositBefore = IBaseVault(_getVault()).maxDeposit(_getActor());
        require(maxDepositBefore > 0, "must be able to deposit");

        depositAmount = between(depositAmount, 1, maxDepositBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        // (uint32 latestDepositApproval,,,) = shareClassManager.epochPointers(scId, assetId);
        (uint128 maxMint,,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
    
        console2.log(" === Before Max Deposit === ");
        console2.log("deposit amount in asyncVault_maxDeposit: ", depositAmount);
        vm.prank(_getActor());
        try IBaseVault(_getVault()).deposit(depositAmount, _getActor()) returns (uint256 shares) {
            console2.log(" === After Max Deposit === ");
            uint256 maxDepositAfter = IBaseVault(_getVault()).maxDeposit(_getActor());
            uint256 difference = maxDepositBefore - depositAmount;

            // optimizing the difference to see if we can get it to more than 1 wei optimize_maxDeposit_difference property 
            if(maxDepositAfter > difference) {
                maxDepositDifference = int256(maxDepositAfter - difference);
            } else {
                maxDepositDifference = int256(difference - maxDepositAfter);
            }

            // console2.log("difference in asyncVault_maxDeposit: ", difference);
            // console2.log("maxDepositAfter in asyncVault_maxDeposit: ", maxDepositAfter);
            // console2.log("maxDepositBefore in asyncVault_maxDeposit: ", maxDepositBefore);
            // console2.log("shares in asyncVault_maxDeposit: ", shares);
            // NOTE: temporarily remove the assertion to optimize the difference
            // otherwise it asserts false and undoes state changes
            // t(difference == maxDepositAfter, "rounding error in maxDeposit");
            
            if(depositAmount == maxDepositBefore) {
                (,,,, uint128 pendingDepositRequest,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
                (uint256 pendingDeposit, ) = shareClassManager.depositRequest(scId, assetId, _getActor().toBytes32());
                
                eq(pendingDepositRequest, 0, "claimableCancelDepositRequest should be 0 after maxDeposit");
                eq(pendingDeposit, 0, "pendingDeposit should be 0 after maxDeposit");
                lte(shares, maxMint, "shares minted surpass maxMint");
            }
        }
        catch {
            // t(latestDepositApproval < depositAmount, "reverts on deposit for approved amount");
        }
    }

    /// @dev Property: user can always maxMint if they have > 0 assets and are approved
    /// @dev Property: user can always mint an amount between 1 and maxMint have > 0 assets and are approved
    /// @dev Property: maxMint should be 0 after using maxMint as mintAmount
    /// @dev Property: minting maxMint should not mint more than maxDeposit shares
    function asyncVault_maxMint(uint64 poolEntropy, uint32 scEntropy, uint256 mintAmount) public statelessTest {
        uint256 maxMintBefore = IBaseVault(_getVault()).maxMint(_getActor());
        uint256 maxDepositBefore = IBaseVault(_getVault()).maxDeposit(_getActor());
        require(maxMintBefore > 0, "must be able to mint");

        mintAmount = between(mintAmount, 1, maxMintBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        (uint32 latestDepositApproval,,,) = shareClassManager.epochId(scId, assetId);
    
        vm.prank(_getActor());
        try IBaseVault(_getVault()).mint(mintAmount, _getActor()) returns (uint256 assets) {
            uint256 maxMintAfter = IBaseVault(_getVault()).maxMint(_getActor());
            uint256 difference = maxMintBefore - mintAmount;
            t(difference == maxMintAfter, "rounding error in maxMint");
            uint256 shares = IBaseVault(_getVault()).convertToShares(assets);

            if(mintAmount == maxMintBefore) {
                (uint128 maxMint,,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
                uint256 maxMintVaultAfter = IBaseVault(_getVault()).maxMint(_getActor());

                eq(maxMint, 0, "maxMint in request should be 0 after maxMint");
                eq(maxMintVaultAfter, 0, "maxMint in vault should be 0 after maxMint");
                lte(shares, maxDepositBefore, "shares minted surpass maxMint");
            }
        }
        catch {
            t(latestDepositApproval < mintAmount, "reverts on mint for approved amount");
        }
    }

    /// @dev Property: user can always maxWithdraw if they have > 0 shares and are approved
    /// @dev Property: user can always withdraw an amount between 1 and maxWithdraw have > 0 shares and are approved
    /// @dev Property: maxWithdraw should decrease by the amount withdrawn
    function asyncVault_maxWithdraw(uint64 poolEntropy, uint32 scEntropy, uint256 withdrawAmount) public statelessTest {
        uint256 maxWithdrawBefore = IBaseVault(_getVault()).maxWithdraw(_getActor());
        require(maxWithdrawBefore > 0, "must be able to withdraw");

        withdrawAmount = between(withdrawAmount, 1, maxWithdrawBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        (, uint32 latestRedeemApproval,,) = shareClassManager.epochId(scId, assetId);
    
        vm.prank(_getActor());
        try IBaseVault(_getVault()).withdraw(withdrawAmount, _getActor(), _getActor()) returns (uint256 shares) {
            uint256 maxWithdrawAfter = IBaseVault(_getVault()).maxWithdraw(_getActor());
            uint256 difference = maxWithdrawBefore - withdrawAmount;
            uint256 assets = IBaseVault(_getVault()).convertToAssets(shares);
            
            t(difference == maxWithdrawAfter, "rounding error in maxWithdraw");
            
            if(withdrawAmount == maxWithdrawBefore) {
                (,,,,, uint128 pendingWithdrawRequest,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
                (uint256 pendingWithdraw, ) = shareClassManager.redeemRequest(scId, assetId, _getActor().toBytes32());

                eq(pendingWithdrawRequest, 0, "pendingWithdrawRequest should be 0 after maxWithdraw");
                eq(pendingWithdraw, 0, "pendingWithdraw should be 0 after maxWithdraw");
                lte(assets, maxWithdrawBefore, "shares withdrawn surpass maxWithdraw");
            }
        }
        catch {
            // precondition: withdrawing more than 1 wei 
            // NOTE: this is because maxWithdraw rounds up so there's always 1 wei that can't be withdrawn
            if(withdrawAmount > 1) {
                t(latestRedeemApproval < withdrawAmount, "reverts on withdraw for approved amount");
            }
        }
    }

    /// @dev Property: user can always maxRedeem if they have > 0 shares and are approved
    /// @dev Property: user can always redeem an amount between 1 and maxRedeem have > 0 shares and are approved
    /// @dev Property: redeeming maxRedeem leaves user with 0 pending redeem requests
    // function asyncVault_maxRedeem(uint64 poolEntropy, uint32 scEntropy, uint256 redeemAmount) public statelessTest {
    // NOTE: temporarily remove the statelessTest modifier to optimize the difference
    function asyncVault_maxRedeem(uint64 poolEntropy, uint32 scEntropy, uint256 redeemAmount) public {
        uint256 maxRedeemBefore = IBaseVault(_getVault()).maxRedeem(_getActor());
        require(maxRedeemBefore > 0, "must be able to redeem");

        redeemAmount = between(redeemAmount, 1, maxRedeemBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(shareClassManager, poolId, scEntropy);
        AssetId assetId = hubRegistry.currency(poolId);
        (,uint32 latestRedeemApproval,,) = shareClassManager.epochId(scId, assetId);
    
        vm.prank(_getActor());
        try IBaseVault(_getVault()).redeem(redeemAmount, _getActor(), _getActor()) returns (uint256 assets) {
            console2.log(" === After maxRedeem === ");
            uint256 maxRedeemAfter = IBaseVault(_getVault()).maxRedeem(_getActor());
            uint256 difference = maxRedeemBefore - redeemAmount;
            uint256 shares = IBaseVault(_getVault()).convertToShares(assets);

            // console2.log("difference:", difference);
            console2.log("maxRedeemAfter:", maxRedeemAfter);
            console2.log("maxRedeemBefore:", maxRedeemBefore);
            // console2.log("redeemAmount:", redeemAmount);
            // console2.log("shares:", shares);
            // console2.log("assets:", assets);

               // for optimizing the difference between the two
            if(maxRedeemAfter > maxRedeemBefore) {
                maxRedeemDifference = int256(maxRedeemAfter - maxRedeemBefore);
            } else {
                maxRedeemDifference = int256(maxRedeemBefore - maxRedeemAfter);
            }

            address poolEscrow = address(poolEscrowFactory.escrow(IBaseVault(_getVault()).poolId()));
            console2.log("pool escrow balance after maxRedeem: ", MockERC20(address(IBaseVault(_getVault()).asset())).balanceOf(poolEscrow));

            // NOTE: temporarily remove the assertion to optimize the difference
            // otherwise it asserts false and undoes state changes
            // t(difference == maxRedeemAfter, "rounding error in maxRedeem");
            
            if(redeemAmount == maxRedeemBefore) {
                (,,,,, uint128 pendingRedeemRequest,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
                (uint256 pendingRedeem, ) = shareClassManager.redeemRequest(scId, assetId, _getActor().toBytes32());

                eq(pendingRedeemRequest, 0, "pendingRedeemRequest should be 0 after maxRedeem");
                eq(pendingRedeem, 0, "pendingRedeem should be 0 after maxRedeem");
                lte(shares, maxRedeemBefore, "shares redeemed surpass maxRedeem");
            }

        }
        catch {
            // precondition: redeeming more than 1 wei
            // NOTE: this is because maxRedeem rounds up so there's always 1 wei that can't be redeemed
            if(redeemAmount > 1) {
                t(latestRedeemApproval < redeemAmount, "reverts on redeem for approved amount");
            }
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
        if (address(_getVault()) == address(0)) {
            return false;
        }
        if (_getShareToken() == address(0)) {
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
