// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// NOTE: this is a pending interface until we split this into files

import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {GlobalAddress} from "src/types/GlobalAddress.sol";
import {AccountId} from "src/types/AccountId.sol";
import {D18} from "src/types/D18.sol";
import {PoolId} from "src/types/PoolId.sol";

import {IERC7726} from "src/interfaces/IERC7726.sol";

import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

interface IAccounting {
    function createAccount(PoolId poolId, AccountId account, bool isDebitNormal) external;
    function setMetadata(PoolId poolId, AccountId account, bytes calldata metadata) external;
    function updateEntry(AccountId credit, AccountId debit, uint128 value) external;
    function addDebit(AccountId account, uint128 value) external;
    function addCredit(AccountId account, uint128 value) external;
    function lock() external;
    function unlock(PoolId poolId) external;
}

interface IGateway {
    // NOTE: Should the implementation store a mapping by chainId to track...?
    // - allowed pools
    // - allowed share classes
    // - allowed assets
    // That mapping would act as a whitelist for the Gateway to discard messages that contains not allowed
    // pools/shareClasses
    function sendNotifyPool(uint32 chainId, PoolId poolId) external;
    function sendNotifyShareClass(uint32 chainId, PoolId poolId, ShareClassId scId) external;
    function sendNotifyAllowedAsset(PoolId poolId, ShareClassId scId, AssetId assetId, bool isAllowed) external;
    function sendFulfilledDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        GlobalAddress investor,
        uint128 shares,
        uint128 investedAmount
    ) external;
    function sendFulfilledRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        GlobalAddress investor,
        uint128 shares,
        uint128 investedAmount
    ) external;
    function sendFulfilledCancelDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        GlobalAddress investor,
        uint128 canceledAmount,
        uint128 fulfilledInvestedAmount
    ) external;
    function sendFulfilledCancelRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        GlobalAddress investor,
        uint128 canceledShares,
        uint128 fulfilledInvestedAmount
    ) external;
    function sendUnlockTokens(AssetId assetId, GlobalAddress receiver, uint128 assetAmount) external;
}
