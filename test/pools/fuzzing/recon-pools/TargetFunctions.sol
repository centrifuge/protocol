// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";
import {console2} from "forge-std/console2.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

// Source
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {JournalEntry} from "src/common/libraries/JournalEntryLib.sol";
import {AccountId, newAccountId} from "src/common/types/AccountId.sol";

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
        bytes32 salt, 
        bool isIdentityValuation,
        uint24 prefix
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        // add and register asset
        add_new_asset(decimals);
        hub_registerAsset(isoCode); // 4294967295

        // defaults to pool admined by the admin actor (address(this))
        poolId = hub_createPool(address(this), isoCode);
        
        // create holding
        scId = shareClassManager.previewNextShareClassId(poolId);
        AssetId assetId = newAssetId(isoCode); // 4294967295
        shortcut_add_share_class_and_holding(poolId.raw(), salt, scId.raw(), assetId.raw(), isIdentityValuation, prefix);

        return (poolId, scId);
    }

    function shortcut_deposit(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(
            decimals, isoCode, 
            salt, 
            isIdentityValuation, prefix
        );

        // request deposit
        hub_depositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, amount);
        
        // approve and issue shares as the pool admin
        shortcut_approve_and_issue_shares(
            PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, maxApproval, 
            isIdentityValuation, navPerShare
        );

        return (poolId, scId);
    }

    function shortcut_deposit_and_claim(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, salt, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // claim deposit as actor
        hub_claimDeposit(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);

        return (poolId, scId);
    }

    function shortcut_deposit_claim_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, salt, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // claim deposit as actor
        hub_claimDeposit(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);

        // cancel deposit
        hub_cancelDepositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);

        return (poolId, scId);
    }

    function shortcut_deposit_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, salt, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // cancel deposit
        hub_cancelDepositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);

        return (poolId, scId);
    }

    function shortcut_request_deposit_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        uint128 maxApproval,
        D18 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_deposit(
            decimals, isoCode, salt, 
            isIdentityValuation, prefix, amount, maxApproval, navPerShare
        );

        // claim deposit as actor
        hub_claimDeposit(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);

        // cancel deposit
        hub_cancelDepositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);

        return (poolId, scId);
    }

    function shortcut_redeem(
        uint64 poolId,
        bytes16 scId,
        uint128 shareAmount,
        uint32 isoCode,
        uint128 maxApproval,
        D18 navPerShare,
        bool isIdentityValuation
    ) public clearQueuedCalls {
        // request redemption
        hub_redeemRequest(poolId, scId, isoCode, shareAmount);
        
        // approve and revoke shares as the pool admin
        shortcut_approve_and_revoke_shares(
            poolId, scId, isoCode, maxApproval, navPerShare, isIdentityValuation
        );
    }

    function shortcut_claim_redemption(
        uint64 poolId,
        bytes16 scId,
        uint32 isoCode
    ) public clearQueuedCalls {        
        // claim redemption as actor
        hub_claimRedeem(poolId, scId, isoCode);
    }

    function shortcut_redeem_and_claim(
        uint64 poolId,
        bytes16 scId,
        uint128 shareAmount,
        uint32 isoCode,
        uint128 maxApproval,
        D18 navPerShare,
        bool isIdentityValuation
    ) public clearQueuedCalls {
        shortcut_redeem(poolId, scId, shareAmount, isoCode, maxApproval, navPerShare, isIdentityValuation);
        
        // claim redemption as actor
        hub_claimRedeem(poolId, scId, isoCode); 
    }

    // deposit and redeem in one call
    // NOTE: this reimplements logic in the shortcut_deposit_and_claim function but is necessary to avoid stack too deep errors
    function shortcut_deposit_redeem_and_claim(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 depositAmount,
        uint128 shareAmount,
        uint128 maxApproval,
        D18 navPerShare
    ) public clearQueuedCalls {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(
            decimals, isoCode, salt, isIdentityValuation, prefix, depositAmount, maxApproval, navPerShare
        );

        // request redemption
        hub_redeemRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, shareAmount);
        
        // approve and revoke shares as the pool admin
        // revokes the shares that were issued in the deposit
        shortcut_approve_and_revoke_shares(
            PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, _getMultiShareClassMetrics(scId), navPerShare, isIdentityValuation
        );
        

        // claim redemption as actor
        hub_claimRedeem(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);
    }

    // deposit and cancel redemption in one call
    // NOTE: this reimplements logic in the shortcut_deposit_and_claim function but is necessary to avoid stack too deep errors
    function shortcut_deposit_cancel_redemption(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 depositAmount,
        uint128 shareAmount,
        uint128 maxApproval,
        D18 navPerShare
    ) public clearQueuedCalls  {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(
            decimals, isoCode, salt, isIdentityValuation, prefix, depositAmount, maxApproval, navPerShare
        );

        // request redemption
        hub_redeemRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, shareAmount);

        // cancel redemption
        hub_cancelRedeemRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode);
    }

    function shortcut_create_pool_and_update_holding(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt, 
        bool isIdentityValuation,
        uint24 prefix,
        D18 newPrice
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation, prefix);
        AssetId assetId = newAssetId(isoCode);

        transientValuation_setPrice(address(assetId.addr()), hubRegistry.currency(poolId).addr(), newPrice);
        hub_updateHolding(ShareClassId.unwrap(scId), assetId.raw());
        hub_execute_clamped(PoolId.unwrap(poolId));
    }

    function shortcut_create_pool_and_update_holding_amount(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt, 
        bool isIdentityValuation,
        uint24 prefix,
        uint128 amount,
        D18 pricePerUnit,
        uint128 debitAmount,
        uint128 creditAmount
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation, prefix);
        
        {
            AssetId assetId = newAssetId(isoCode);

            JournalEntry[] memory debits = new JournalEntry[](1);
            debits[0] = JournalEntry({
                accountId: newAccountId(prefix, ACCOUNT_TO_UPDATE % 6),
                amount: debitAmount
            });
            JournalEntry[] memory credits = new JournalEntry[](1);
            credits[0] = JournalEntry({
                accountId: newAccountId(prefix, ACCOUNT_TO_UPDATE % 6),
                amount: creditAmount
            });

            hub_updateHoldingAmount(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), assetId.raw(), amount, pricePerUnit, IS_INCREASE, debits, credits);
        }
    }

    function shortcut_create_pool_and_update_holding_value(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt, 
        bool isIdentityValuation,
        uint24 prefix,
        D18 newPrice
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation, prefix);
        AssetId assetId = newAssetId(isoCode);

        hub_updateHoldingValue(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), assetId.raw(), newPrice);
        // hub_execute_clamped(poolId);
    }

    function shortcut_create_pool_and_update_journal(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt, 
        bool isIdentityValuation,
        uint24 prefix,
        uint8 accountToUpdate,
        uint128 debitAmount,
        uint128 creditAmount
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation, prefix);

        {
            AccountId accountId = newAccountId(prefix, accountToUpdate % 6);
            JournalEntry[] memory debits = new JournalEntry[](1);
            debits[0] = JournalEntry({
                accountId: accountId,
                amount: debitAmount
            });
            JournalEntry[] memory credits = new JournalEntry[](1);
            credits[0] = JournalEntry({
                accountId: accountId,
                amount: creditAmount
            });

            hub_updateJournal(PoolId.unwrap(poolId), debits, credits);
        }
    }

    // change price and update holding for most recent poolId
    function shortcut_update_holding(
        uint32 isoCode, 
        D18 newPrice
    ) public clearQueuedCalls  {
        PoolId poolId = newPoolId(CENTIFUGE_CHAIN_ID, hubRegistry.latestId());
        
        ShareClassId nextScId = shareClassManager.previewNextShareClassId(poolId);
        // get the current share class id by decrementing the next share class id
        ShareClassId scId = ShareClassId.wrap(bytes16(uint128(nextScId.raw()) - 1)); 

        AssetId assetId = newAssetId(isoCode);
        transientValuation_setPrice(address(assetId.addr()), address(assetId.addr()), newPrice);

        hub_updateHolding(scId.raw(), assetId.raw());
        hub_execute_clamped(poolId.raw());
    }

    function shortcut_update_valuation(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt, 
        bool isIdentityValuation,
        uint24 prefix
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");
        
        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation, prefix);
    
        AssetId assetId = newAssetId(isoCode);
        hub_updateHoldingValuation(ShareClassId.unwrap(scId), assetId.raw(), isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation)));
        hub_execute_clamped(PoolId.unwrap(poolId));
    }

    function shortcut_notify_share_class(
        uint8 decimals,
        uint32 isoCode,
        bytes32 salt,
        bool isIdentityValuation,
        uint24 prefix,
        uint128 depositAmount,
        uint128 shareAmount,
        D18 navPerShare
    ) public clearQueuedCalls  {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(decimals, isoCode, salt, isIdentityValuation, prefix, depositAmount, shareAmount, navPerShare);

        // set chainId and hook to constants because we're mocking Gateway so they're not needed
        hub_notifyShareClass(0, ShareClassId.unwrap(scId), bytes32("ExampleHookData"));
        hub_execute_clamped(PoolId.unwrap(poolId));
    }

    /// === POOL ADMIN SHORTCUTS === ///
    /// @dev these don't have the clearQueuedCalls modifier because they just add additional calls to the queue and execute so don't make debugging difficult

    function shortcut_add_share_class_and_holding(
        uint64 poolId,
        bytes32 salt,
        bytes16 scId,
        uint128 assetId,
        bool isIdentityValuation,
        uint24 prefix
    ) public  {
        hub_addShareClass(salt);

        IERC7726 valuation = isIdentityValuation ? 
            IERC7726(address(identityValuation)) : 
            IERC7726(address(transientValuation));

        // hub_createHolding(scId, assetId, valuation, prefix);
        hub_createHolding(scId, assetId, valuation, IS_LIABILITY, prefix);
        hub_execute_clamped(poolId);
    }

    function shortcut_approve_and_issue_shares(
        uint64 poolId,
        bytes16 scId,
        uint32 isoCode,
        uint128 maxApproval, 
        bool isIdentityValuation,
        D18 navPerShare
    ) public  {
        AssetId assetId = newAssetId(isoCode);

        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));

        transientValuation.setPrice(address(assetId.addr()), address(assetId.addr()), INITIAL_PRICE);

        hub_approveDeposits(scId, assetId.raw(), maxApproval, valuation);
        hub_issueShares(scId, assetId.raw(), navPerShare);
        hub_execute_clamped(poolId);

        // reset the epoch increment to 0 so that the next approval is in a "new tx"
        _setEpochIncrement(0);
    }

    function shortcut_approve_and_revoke_shares(
        uint64 poolId,
        bytes16 scId,
        uint32 isoCode,
        uint128 maxApproval,
        D18 navPerShare,
        bool isIdentityValuation
    ) public  {        
        IERC7726 valuation = isIdentityValuation ? IERC7726(address(identityValuation)) : IERC7726(address(transientValuation));
        
        hub_approveRedeems(scId, isoCode, maxApproval);
        hub_revokeShares(scId, isoCode, navPerShare, valuation);
        hub_execute_clamped(poolId);

        // reset the epoch increment to 0 so that the next approval is in a "new tx"
        _setEpochIncrement(0);
    }

    function shortcut_update_restriction(
        uint16 poolIdEntropy,
        uint16 shareClassEntropy,
        bytes calldata payload
    ) public {
        if(createdPools.length > 0) {
            // get a random pool id
            PoolId poolId = createdPools[poolIdEntropy % createdPools.length];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);
            
            // get a random share class id
            ShareClassId scId = shareClassManager.previewShareClassId(poolId, shareClassEntropy % shareClassCount);
            hub_updateRestriction(CENTIFUGE_CHAIN_ID, scId.raw(), payload);
            hub_execute_clamped(poolId.raw());
        }
    }

    /// === Transient Valuation === ///
    function transientValuation_setPrice(address base, address quote, D18 price) public {
        transientValuation.setPrice(base, quote, price);
    }

    // set the price of the asset in the transient valuation for a given pool
    function transientValuation_setPrice_clamped(uint64 poolId, D18 price) public {
        AssetId assetId = hubRegistry.currency(PoolId.wrap(poolId));

        transientValuation.setPrice(address(assetId.addr()), address(assetId.addr()), price);
    }

    /// === Gateway === ///
    function gateway_topUp() public payable {
        gateway.topUp{value: msg.value}();
    }

    /// === Helpers === ///
    /// @dev helper to toggle the isLiability boolean for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too deep error
    function toggle_IsLiability() public {
        IS_LIABILITY = !IS_LIABILITY;
    }

    /// @dev helper to toggle the isIncrease boolean for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too deep error
    function toggle_IsIncrease() public {
        IS_INCREASE = !IS_INCREASE;
    }

    /// @dev helper to toggle the accountToUpdate uint8 for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too deep error
    function toggle_AccountToUpdate(uint8 accountToUpdate) public {
        ACCOUNT_TO_UPDATE = accountToUpdate;
    }

    /// helper to set the epoch increment for the multi share class for multiple calls to approvals in same transaction
    function _setEpochIncrement(uint32 epochIncrement) internal {
        shareClassManager.setEpochIncrement(epochIncrement);
    }

    function _getMultiShareClassMetrics(ShareClassId scId) internal view returns (uint128 totalIssuance) {
        (totalIssuance,) = shareClassManager.metrics(scId);
        return totalIssuance;
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
