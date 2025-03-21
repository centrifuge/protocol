// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {console2} from "forge-std/console2.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

// Source
import {AssetId, newAssetId} from "src/pools/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {PoolId, newPoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";

import {AdminTargets} from "./targets/AdminTargets.sol";
import {Helpers} from "./utils/Helpers.sol";
import {ManagerTargets} from "./targets/ManagerTargets.sol";
import {PoolRouterTargets} from "./targets/PoolRouterTargets.sol";

abstract contract TargetFunctions is
    AdminTargets,
    ManagerTargets,
    PoolRouterTargets
{
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// === SHORTCUT FUNCTIONS === ///
    // shortcuts for the most common calls that are needed to achieve coverage


    function shortcut_create_pool_and_holding(
        uint8 decimals,
        uint32 isoCode,
        string memory name, 
        string memory symbol, 
        bytes32 salt, 
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix
    ) public returns (PoolId poolId, ShareClassId scId) {
        // add and register asset
        add_new_asset(decimals);
        poolRouter_registerAsset(isoCode);

        // defaults to pool admined by the admin actor (address(this))
        poolId = poolRouter_createPool(address(this), isoCode, multiShareClass);
        
        // create holding
        scId = multiShareClass.previewNextShareClassId(poolId);
        AssetId assetId = newAssetId(isoCode);
        shortcut_add_share_class_and_holding(poolId, name, symbol, salt, data, scId, assetId, isIdentityValuation, prefix);
        
        return (poolId, scId);
    }

    function shortcut_deposit(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = shortcut_create_pool_and_holding(
            decimals, isoCode, 
            name, symbol, salt, data, 
            isIdentityValuation, prefix
        );

        // request deposit
        poolRouter_depositRequest(poolId, scId, isoCode, amount);
        
        // approve and issue shares as the pool admin
        shortcut_approve_and_issue_shares(
            poolId, scId, isoCode, maxApproval, 
            isIdentityValuation, navPerShare
        );

        return (poolId, scId);
    }

    function shortcut_deposit_and_claim(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, name, symbol, salt, data, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // claim deposit as actor
        poolRouter_claimDeposit(poolId, scId, isoCode);

        return (poolId, scId);
    }

    function shortcut_deposit_claim_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, name, symbol, salt, data, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // claim deposit as actor
        poolRouter_claimDeposit(poolId, scId, isoCode);

        // cancel deposit
        poolRouter_cancelDepositRequest(poolId, scId, isoCode);

        return (poolId, scId);
    }

     function shortcut_deposit_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, name, symbol, salt, data, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // cancel deposit
        poolRouter_cancelDepositRequest(poolId, scId, isoCode);

        return (poolId, scId);
    }

    function shortcut_request_deposit_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public returns (PoolId poolId, ShareClassId scId) {
        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, name, symbol, salt, data, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // claim deposit as actor
        poolRouter_claimDeposit(poolId, scId, isoCode);

        // cancel deposit
        poolRouter_cancelDepositRequest(poolId, scId, isoCode);

        return (poolId, scId);
    }

    function shortcut_redeem(
        PoolId poolId,
        ShareClassId scId,
        uint128 shareAmount,
        uint32 isoCode,
        uint128 maxApproval,
        D18 navPerShare,
        bool isIdentityValuation
    ) public {
        // request redemption
        poolRouter_redeemRequest(poolId, scId, isoCode, shareAmount);
        
        // approve and revoke shares as the pool admin
        shortcut_approve_and_revoke_shares(
            poolId, scId, isoCode, maxApproval, navPerShare, isIdentityValuation
        );
    }

    function shortcut_claim_redemption(
        PoolId poolId,
        ShareClassId scId,
        uint32 isoCode
    ) public {        
        // claim redemption as actor
        poolRouter_claimRedeem(poolId, scId, isoCode);
    }


    function shortcut_redeem_and_claim(
        PoolId poolId,
        ShareClassId scId,
        uint128 shareAmount,
        uint32 isoCode,
        uint128 maxApproval,
        D18 navPerShare,
        bool isIdentityValuation
    ) public {
        shortcut_redeem(poolId, scId, shareAmount, isoCode, maxApproval, navPerShare, isIdentityValuation);
        
        // claim redemption as actor
        poolRouter_claimRedeem(poolId, scId, isoCode); 
    }

    // deposit and redeem in one call
    // NOTE: this reimplements logic in the shortcut_deposit_and_claim function but is necessary to avoid stack too deep errors
    function shortcut_deposit_redeem_and_claim(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 depositAmount,
        uint128 shareAmount,
        uint128 maxApproval,
        D18 navPerShare
    ) public {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(
            decimals, isoCode, name, symbol, salt, data, isIdentityValuation, prefix, depositAmount, maxApproval, navPerShare
        );

        // request redemption
        poolRouter_redeemRequest(poolId, scId, isoCode, shareAmount);
        
        // approve and revoke shares as the pool admin
        // revokes the shares that were issued in the deposit
        shortcut_approve_and_revoke_shares(
            poolId, scId, isoCode, _getMultiShareClassMetrics(scId), navPerShare, isIdentityValuation
        );
        

        // claim redemption as actor
        poolRouter_claimRedeem(poolId, scId, isoCode);
    }

    function _getMultiShareClassMetrics(ShareClassId scId) internal view returns (uint128 totalIssuance) {
        (totalIssuance,) = multiShareClass.metrics(scId);
        return totalIssuance;
    }

    // deposit and cancel redemption in one call
    // NOTE: this reimplements logic in the shortcut_deposit_and_claim function but is necessary to avoid stack too deep errors
    function shortcut_deposit_cancel_redemption(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 depositAmount,
        uint128 shareAmount,
        uint128 maxApproval,
        D18 navPerShare
    ) public  {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(
            decimals, isoCode, name, symbol, salt, data, isIdentityValuation, prefix, depositAmount, maxApproval, navPerShare
        );

        // request redemption
        poolRouter_redeemRequest(poolId, scId, isoCode, shareAmount);

        // cancel redemption
        poolRouter_cancelRedeemRequest(poolId, scId, isoCode);
    }

    function shortcut_create_pool_and_update_holding(
        uint8 decimals,
        uint32 isoCode,
        string memory name, 
        string memory symbol, 
        bytes32 salt, 
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        D18 newPrice
    ) public  {
        (PoolId poolId, ShareClassId scId) = shortcut_create_pool_and_holding(decimals, isoCode, name, symbol, salt, data, isIdentityValuation, prefix);
    
        AssetId assetId = newAssetId(isoCode);
        transientValuation_setPrice(assetId.addr(), poolRegistry.currency(poolId).addr(), newPrice);

        poolRouter_updateHolding(scId, assetId);

        poolRouter_execute_clamped(poolId);
    }

    // change price and update holding for most recent poolId
    function shortcut_update_holding(
        uint32 isoCode, 
        D18 newPrice
    ) public  {
        PoolId poolId = newPoolId(poolRegistry.latestId());
        
        ShareClassId nextScId = multiShareClass.previewNextShareClassId(poolId);
        // get the current share class id by decrementing the next share class id
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(ShareClassId.unwrap(nextScId)) - 1)); 

        AssetId assetId = newAssetId(isoCode);
        transientValuation_setPrice(assetId.addr(), poolRegistry.currency(poolId).addr(), newPrice);

        poolRouter_updateHolding(scId, assetId);
        poolRouter_execute_clamped(poolId);
    }

    function shortcut_update_valuation(
        uint8 decimals,
        uint32 isoCode,
        string memory name, 
        string memory symbol, 
        bytes32 salt, 
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix
    ) public  {
        (PoolId poolId, ShareClassId scId) = shortcut_create_pool_and_holding(decimals, isoCode, name, symbol, salt, data, isIdentityValuation, prefix);
    
        AssetId assetId = newAssetId(isoCode);
        poolRouter_updateHoldingValuation(scId, assetId, isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation)));
        poolRouter_execute_clamped(poolId);
    }

    function shortcut_notify_share_class(
        uint8 decimals,
        uint32 isoCode,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 depositAmount,
        uint128 shareAmount,
        D18 navPerShare
    ) public  {
        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(decimals, isoCode, name, symbol, salt, data, isIdentityValuation, prefix, depositAmount, shareAmount, navPerShare);

        // set chainId and hook to constants because we're mocking Gateway so they're not needed
        poolRouter_notifyShareClass(0, scId, bytes32("ExampleHookData"));
        poolRouter_execute_clamped(poolId);
    }

    /// === POOL ADMIN SHORTCUTS === ///
    function shortcut_add_share_class_and_holding(
        PoolId poolId,
        string memory name,
        string memory symbol,
        bytes32 salt,
        bytes memory data,
        ShareClassId scId,
        AssetId assetId,
        bool isIdentityValuation,
        uint24 prefix
    ) public  {
        poolRouter_addShareClass(name, symbol, salt, data);

        IERC7726 valuation = isIdentityValuation ? 
            IERC7726(address(identityValuation)) : 
            IERC7726(address(transientValuation));

        poolRouter_createHolding(scId, assetId, valuation, prefix);
        poolRouter_execute_clamped(poolId);
    }

    function shortcut_approve_and_issue_shares(
        PoolId poolId,
        ShareClassId scId,
        uint32 isoCode,
        uint128 maxApproval, 
        bool isIdentityValuation,
        D18 navPerShare
    ) public  {
        AssetId assetId = newAssetId(isoCode);

        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));

        transientValuation.setPrice(assetId.addr(), assetId.addr(), INITIAL_PRICE);

        poolRouter_approveDeposits(scId, assetId, maxApproval, valuation);
        poolRouter_issueShares(scId, assetId, navPerShare);
        poolRouter_execute_clamped(poolId);
    }

    function shortcut_approve_and_revoke_shares(
        PoolId poolId,
        ShareClassId scId,
        uint32 isoCode,
        uint128 maxApproval,
        D18 navPerShare,
        bool isIdentityValuation
    ) public  {        
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        
        poolRouter_approveRedeems(scId, isoCode, maxApproval);
        poolRouter_revokeShares(scId, isoCode, navPerShare, valuation);
        poolRouter_execute_clamped(poolId);
    }

    /// === Transient Valuation === ///
    function transientValuation_setPrice(address base, address quote, D18 price) public {
        transientValuation.setPrice(base, quote, price);
    }

    // set the price of the asset in the transient valuation for a given pool
    function transientValuation_setPrice_clamped(PoolId poolId, D18 price) public {
        AssetId assetId = poolRegistry.currency(poolId);

        transientValuation.setPrice(assetId.addr(), assetId.addr(), price);
    }

    /// === Gateway === ///
    function gateway_topUp() public payable {
        gateway.topUp{value: msg.value}();
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
