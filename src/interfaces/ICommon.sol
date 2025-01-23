// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

// NOTE: this is a pending interface until we split this into files

import {ChainId} from "src/types/ChainId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {GlobalAddress} from "src/types/GlobalAddress.sol";
import {AccountId} from "src/types/AccountId.sol";
import {D18} from "src/types/D18.sol";
import {PoolId} from "src/types/PoolId.sol";

import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

import {PoolLocker} from "src/PoolLocker.sol";
import {Auth} from "src/Auth.sol";

interface IAssetManager is IERC6909 {
    function mint(address who, AssetId assetId, uint128 amount) external;
    function burn(address who, AssetId assetId, uint128 amount) external;
    function isRegistered(AssetId assetId) external view returns (bool);
}

interface IAccounting {
    function updateEntry(AccountId credit, AccountId debit, uint128 value) external;
    function lock(PoolId poolId) external;
}

interface IGateway {
    // NOTE: Should the implementation store a mapping by chainId to track...?
    // - allowed pools
    // - allowed share classes
    // - allowed assets
    // That mapping would act as a whitelist for the Gateway to discard messages that contains not allowed
    // pools/shareClasses
    function sendNotifyPool(ChainId chainId, PoolId poolId) external;
    function sendNotifyShareClass(ChainId chainId, PoolId poolId, ShareClassId scId) external;
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
