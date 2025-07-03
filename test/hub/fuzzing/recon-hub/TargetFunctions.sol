// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

// Chimera deps
import {vm} from "@chimera/Hevm.sol";

// Helpers
import {Panic} from "@recon/Panic.sol";

// Source
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {D18} from "src/misc/types/D18.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {JournalEntry} from "src/hub/interfaces/IAccounting.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import {AdminTargets} from "./targets/AdminTargets.sol";
import {Helpers} from "./utils/Helpers.sol";
import {ManagerTargets} from "./targets/ManagerTargets.sol";
import {HubTargets} from "./targets/HubTargets.sol";
import {ToggleTargets} from "./targets/ToggleTargets.sol";

abstract contract TargetFunctions is AdminTargets, ManagerTargets, HubTargets, ToggleTargets {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// === SHORTCUT FUNCTIONS === ///
    // shortcuts for the most common calls that are needed to achieve coverage

    function shortcut_create_pool_and_holding(uint8 decimals, uint32 isoCode, uint256 salt, bool isIdentityValuation)
        public
        clearQueuedCalls
        returns (PoolId poolId, ShareClassId scId)
    {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        // add and register asset
        add_new_asset(decimals);
        hub_registerAsset(isoCode); // 4294967295
        // TODO(wischli): Investigate re-enabling when decoupling pool currency from asset id
        // transientValuation.file("erc6909", address(_getAsset()));

        // defaults to pool admined by the admin actor (address(this))
        poolId = hub_createPool(address(this), POOL_ID_COUNTER++, isoCode);

        // create holding
        scId = shareClassManager.previewNextShareClassId(poolId);
        shortcut_add_share_class_and_holding(poolId.raw(), salt, scId.raw(), isIdentityValuation);

        return (poolId, scId);
    }

    function shortcut_deposit(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 amount,
        uint128 maxApproval,
        uint128 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation);

        // request deposit
        hub_depositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), amount);

        // approve and issue shares as the pool admin
        shortcut_approve_and_issue_shares(
            PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, maxApproval, isIdentityValuation, navPerShare
        );

        return (poolId, scId);
    }

    function shortcut_deposit_and_claim(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 amount,
        uint128 maxApproval,
        uint128 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) =
            shortcut_deposit(decimals, isoCode, salt, isIdentityValuation, amount, maxApproval, navPerShare);

        AssetId assetId = newAssetId(isoCode);
        // claim deposit as actor
        hub_notifyDeposit(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), assetId.raw(), MAX_CLAIMS);

        return (poolId, scId);
    }

    function shortcut_deposit_claim_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 amount,
        uint128 maxApproval,
        uint128 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) =
            shortcut_deposit(decimals, isoCode, salt, isIdentityValuation, amount, maxApproval, navPerShare);

        // claim deposit as actor
        AssetId assetId = hubRegistry.currency(poolId);
        hub_notifyDeposit(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), assetId.raw(), MAX_CLAIMS);

        // cancel deposit
        hub_cancelDepositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId));

        return (poolId, scId);
    }

    function shortcut_deposit_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 amount,
        uint128 maxApproval,
        uint128 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) =
            shortcut_deposit(decimals, isoCode, salt, isIdentityValuation, amount, maxApproval, navPerShare);

        // cancel deposit
        hub_cancelDepositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId));

        return (poolId, scId);
    }

    function shortcut_request_deposit_and_cancel(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 amount,
        uint128 maxApproval,
        uint128 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) =
            shortcut_deposit(decimals, isoCode, salt, isIdentityValuation, amount, maxApproval, navPerShare);

        // claim deposit as actor
        AssetId assetId = newAssetId(isoCode);
        hub_notifyDeposit(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), assetId.raw(), MAX_CLAIMS);

        // cancel deposit
        hub_cancelDepositRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId));

        return (poolId, scId);
    }

    function shortcut_redeem(
        uint64 poolId,
        bytes16 scId,
        uint128 shareAmount,
        uint32 isoCode,
        uint128 maxApproval,
        uint128 navPerShare,
        bool isIdentityValuation
    ) public clearQueuedCalls {
        // request redemption
        hub_redeemRequest(poolId, scId, isoCode, shareAmount);

        // approve and revoke shares as the pool admin
        shortcut_approve_and_revoke_shares(poolId, scId, isoCode, maxApproval, navPerShare, isIdentityValuation);
    }

    function shortcut_claim_redemption(uint64 poolId, bytes16 scId, uint32 isoCode) public clearQueuedCalls {
        // claim redemption as actor
        AssetId assetId = newAssetId(isoCode);
        hub_notifyRedeem(poolId, scId, assetId.raw(), MAX_CLAIMS);
    }

    function shortcut_redeem_and_claim(
        uint64 poolId,
        bytes16 scId,
        uint128 shareAmount,
        uint32 isoCode,
        uint128 maxApproval,
        uint128 navPerShare,
        bool isIdentityValuation
    ) public clearQueuedCalls {
        shortcut_redeem(poolId, scId, shareAmount, isoCode, maxApproval, navPerShare, isIdentityValuation);

        // claim redemption as actor
        AssetId assetId = newAssetId(isoCode);
        hub_notifyRedeem(poolId, scId, assetId.raw(), MAX_CLAIMS);
    }

    // deposit and redeem in one call
    // NOTE: this reimplements logic in the shortcut_deposit_and_claim function but is necessary to avoid stack too deep
    // errors
    function shortcut_deposit_redeem_and_claim(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 depositAmount,
        uint128 shareAmount,
        uint128 navPerShare
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_deposit_and_claim(
            decimals, isoCode, salt, isIdentityValuation, depositAmount, depositAmount, navPerShare
        );

        // request redemption
        hub_redeemRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, shareAmount);

        // approve and revoke shares as the pool admin
        // revokes the shares that were issued in the deposit
        shortcut_approve_and_revoke_shares(
            PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, shareAmount, navPerShare, isIdentityValuation
        );

        // claim redemption as actor
        AssetId assetId = newAssetId(isoCode);
        hub_notifyRedeem(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), assetId.raw(), MAX_CLAIMS);

        return (poolId, scId);
    }

    // deposit and cancel redemption in one call
    // NOTE: this reimplements logic in the shortcut_deposit_and_claim function but is necessary to avoid stack too deep
    // errors
    function shortcut_deposit_cancel_redemption(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 depositAmount,
        uint128 shareAmount,
        uint128 navPerShare
    ) public clearQueuedCalls {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(
            decimals, isoCode, salt, isIdentityValuation, depositAmount, depositAmount, navPerShare
        );

        // request redemption
        hub_redeemRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), isoCode, shareAmount);

        // cancel redemption
        hub_cancelRedeemRequest(PoolId.unwrap(poolId), ShareClassId.unwrap(scId));
    }

    function shortcut_create_pool_and_update_holding(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 newPrice
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation);
        AssetId assetId = newAssetId(isoCode);

        transientValuation_setPrice(assetId, assetId, newPrice);
    }

    function shortcut_create_pool_and_update_holding_amount(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 amount,
        uint128 pricePoolPerAsset,
        uint128 debitAmount,
        uint128 creditAmount
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation);

        {
            AssetId assetId = newAssetId(isoCode);

            JournalEntry[] memory debits = new JournalEntry[](1);
            debits[0] = JournalEntry({value: debitAmount, accountId: ACCOUNT_TO_UPDATE});
            JournalEntry[] memory credits = new JournalEntry[](1);
            credits[0] = JournalEntry({value: creditAmount, accountId: ACCOUNT_TO_UPDATE});

            hub_updateHoldingAmount(
                PoolId.unwrap(poolId),
                ShareClassId.unwrap(scId),
                assetId.raw(),
                amount,
                pricePoolPerAsset,
                IS_INCREASE,
                IS_SNAPSHOT,
                NONCE
            );
        }
    }

    function shortcut_create_pool_and_update_holding_value(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation);
        AssetId assetId = newAssetId(isoCode);

        if (!isIdentityValuation) {
            transientValuation_setPrice(assetId, assetId, INITIAL_PRICE.raw());
        }

        hub_updateHoldingValue(PoolId.unwrap(poolId), ShareClassId.unwrap(scId), assetId.raw());
    }

    function shortcut_create_pool_and_update_journal(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint8 accountToUpdate,
        uint128 debitAmount,
        uint128 creditAmount
    ) public clearQueuedCalls returns (PoolId poolId, ShareClassId scId) {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation);

        {
            AccountId accountId = createdAccountIds[accountToUpdate % createdAccountIds.length];
            JournalEntry[] memory debits = new JournalEntry[](1);
            debits[0] = JournalEntry({value: debitAmount, accountId: accountId});
            JournalEntry[] memory credits = new JournalEntry[](1);
            credits[0] = JournalEntry({value: creditAmount, accountId: accountId});

            hub_updateJournal(PoolId.unwrap(poolId), debits, credits);
        }
    }

    function shortcut_update_valuation(uint8 decimals, uint32 isoCode, uint256 salt, bool isIdentityValuation)
        public
        clearQueuedCalls
        returns (PoolId poolId, ShareClassId scId)
    {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (poolId, scId) = shortcut_create_pool_and_holding(decimals, isoCode, salt, isIdentityValuation);

        AssetId assetId = newAssetId(isoCode);
        hub_updateHoldingValuation(
            poolId.raw(),
            ShareClassId.unwrap(scId),
            assetId.raw(),
            isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation))
        );
    }

    function shortcut_notify_share_class(
        uint8 decimals,
        uint32 isoCode,
        uint256 salt,
        bool isIdentityValuation,
        uint128 depositAmount,
        uint128 shareAmount,
        uint128 navPerShare
    ) public clearQueuedCalls {
        decimals %= 24; // upper bound of decimals for most ERC20s is 24
        require(decimals >= 6, "decimals must be >= 6");

        (PoolId poolId, ShareClassId scId) = shortcut_deposit_and_claim(
            decimals, isoCode, salt, isIdentityValuation, depositAmount, depositAmount, navPerShare
        );

        // set chainId and hook to constants because we're mocking Gateway so they're not needed
        hub_notifyShareClass(poolId.raw(), CENTIFUGE_CHAIN_ID, ShareClassId.unwrap(scId), bytes32("ExampleHookData"));
    }

    /// === POOL ADMIN SHORTCUTS === ///
    /// @dev these don't have the clearQueuedCalls modifier because they just add additional calls to the queue and
    /// execute so don't make debugging difficult

    function shortcut_add_share_class_and_holding(uint64 poolId, uint256 salt, bytes16 scId, bool isIdentityValuation)
        public
    {
        hub_addShareClass(poolId, salt);

        IValuation valuation =
            isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));

        hub_createAccount(poolId, ASSET_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId, EQUITY_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId, LOSS_ACCOUNT, IS_DEBIT_NORMAL);
        hub_createAccount(poolId, GAIN_ACCOUNT, IS_DEBIT_NORMAL);

        hub_initializeHolding(poolId, scId, valuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, LOSS_ACCOUNT, GAIN_ACCOUNT);
    }

    function shortcut_approve_and_issue_shares(
        uint64 poolId,
        bytes16 scId,
        uint32 isoCode,
        uint128 maxApproval,
        bool isIdentityValuation,
        uint128 navPerShare
    ) public {
        AssetId assetId = newAssetId(isoCode);

        IValuation valuation =
            isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));

        transientValuation_setPrice(assetId, assetId, INITIAL_PRICE.raw());

        uint32 depositEpochId = shareClassManager.nowDepositEpoch(ShareClassId.wrap(scId), assetId);
        hub_approveDeposits(poolId, scId, assetId.raw(), depositEpochId, maxApproval);
        hub_issueShares(poolId, scId, assetId.raw(), depositEpochId, navPerShare);
    }

    function shortcut_approve_and_revoke_shares(
        uint64 poolId,
        bytes16 scId,
        uint32 isoCode,
        uint128 maxApproval,
        uint128 navPerShare,
        bool isIdentityValuation
    ) public {
        IValuation valuation =
            isIdentityValuation ? IValuation(address(identityValuation)) : IValuation(address(transientValuation));

        AssetId assetId = newAssetId(isoCode);

        uint32 redeemEpochId = shareClassManager.nowRedeemEpoch(ShareClassId.wrap(scId), assetId);
        hub_approveRedeems(poolId, scId, assetId.raw(), redeemEpochId, maxApproval);
        hub_revokeShares(poolId, scId, redeemEpochId, navPerShare);
    }

    function shortcut_update_restriction(uint16 poolIdEntropy, uint16 shareClassEntropy, bytes calldata payload)
        public
    {
        if (createdPools.length > 0) {
            // get a random pool id
            PoolId poolId = createdPools[poolIdEntropy % createdPools.length];
            uint32 shareClassCount = shareClassManager.shareClassCount(poolId);

            // get a random share class id
            ShareClassId scId = shareClassManager.previewShareClassId(poolId, shareClassEntropy % shareClassCount);
            hub_updateRestriction(poolId.raw(), scId.raw(), CENTIFUGE_CHAIN_ID, payload);
        }
    }

    /// === Transient Valuation === ///
    function transientValuation_setPrice(AssetId base, AssetId quote, uint128 price) public {
        transientValuation.setPrice(base, quote, D18.wrap(price));
    }

    // set the price of the asset in the transient valuation for a given pool
    function transientValuation_setPrice_clamped(uint64 poolId, uint128 price) public {
        AssetId assetId = hubRegistry.currency(PoolId.wrap(poolId));

        transientValuation_setPrice(assetId, assetId, price);
    }

    /// === Gateway === ///
    function gateway_subsidizePool(uint64 poolId) public payable {
        gateway.subsidizePool{value: msg.value}(poolId);
    }

    function _getMultiShareClassMetrics(ShareClassId scId) internal view returns (uint128 totalIssuance) {
        (totalIssuance,) = shareClassManager.metrics(scId);
        return totalIssuance;
    }

    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
}
