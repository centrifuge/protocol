// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

/// @notice Entry point to the system
interface IPoolRouter {
    /// @notice Main method to unlock the pool and call the rest of the admin methods
    function execute(PoolId poolId, bytes[] calldata data) external payable;

    /// @notice See counterpart in PoolManager contract
    function createPool(AssetId currency, IShareClassManager shareClassManager) external returns (PoolId poolId);

    /// @notice See counterpart in PoolManager contract
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external;

    /// @notice See counterpart in PoolManager contract
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external;

    /// @notice See counterpart in PoolManager contract
    function notifyPool(uint32 chainId) external;

    /// @notice See counterpart in PoolManager contract
    function notifyShareClass(uint32 chainId, ShareClassId scId, bytes32 hook) external;

    /// @notice See counterpart in PoolManager contract
    function setPoolMetadata(bytes calldata metadata) external;

    /// @notice See counterpart in PoolManager contract
    function allowPoolAdmin(address account, bool allow) external;

    /// @notice See counterpart in PoolManager contract
    function allowAsset(ShareClassId scId, AssetId assetId, bool allow) external;

    /// @notice See counterpart in PoolManager contract
    function addShareClass(string calldata name, string calldata symbol, bytes32 salt, bytes calldata data) external;

    /// @notice See counterpart in PoolManager contract
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, uint128 maxApproval, IERC7726 valuation)
        external;

    /// @notice See counterpart in PoolManager contract
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, uint128 maxApproval) external;

    /// @notice See counterpart in PoolManager contract
    function issueShares(ShareClassId scId, AssetId depositAssetId, D18 navPerShare) external;

    /// @notice See counterpart in PoolManager contract
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation) external;

    /// @notice See counterpart in PoolManager contract
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint24 prefix) external;

    /// @notice See counterpart in PoolManager contract
    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) external;

    /// @notice See counterpart in PoolManager contract
    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) external;

    /// @notice See counterpart in PoolManager contract
    function updateHolding(ShareClassId scId, AssetId assetId) external;

    /// @notice See counterpart in PoolManager contract
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external;

    /// @notice See counterpart in PoolManager contract
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external;

    /// @notice See counterpart in PoolManager contract
    function createAccount(AccountId account, bool isDebitNormal) external;

    /// @notice See counterpart in PoolManager contract
    function setAccountMetadata(AccountId account, bytes calldata metadata) external;

    /// @notice See counterpart in PoolManager contract
    function addDebit(AccountId account, uint128 amount) external;

    /// @notice See counterpart in PoolManager contract
    function addCredit(AccountId account, uint128 amount) external;
}
