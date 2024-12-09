// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ChainId, PoolId, ShareClassId, AssetId, Ratio, ItemId} from "src/types/Domain.sol";

import {IItemManager} from "src/interfaces/ICommon.sol";

/// @dev interface for methods that requires the pool to be unlocked
/// NOTE: They do not require a poolId parameter although they acts over an specific pool
interface IPoolUnlockedMethods {
    function allowPool(ChainId chainId) external;

    function allowShareClass(ChainId chainId, ShareClassId scId) external;

    function approveDeposit(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function updateHoldings(ShareClassId scId, AssetId assetId, uint128 amount) external;

    function increaseDebt(IItemManager im, ShareClassId scId, ItemId itemId, uint128 amount) external;

    function decreasePrincipalDebt(IItemManager im, ShareClassId scId, ItemId itemId, uint128 amount) external;

    function decreaseInterestDebt(IItemManager im, ShareClassId scId, ItemId itemId, uint128 amount) external;

    function issueShares(ShareClassId id, uint128 nav) external;
}

interface IPoolManager is IPoolUnlockedMethods {
    error NotAllowed();

    function createPool() external returns (PoolId poolId);

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, address investor, uint128 amount)
        external;

    function claimShares(PoolId poolId, ShareClassId scId, AssetId assetId, address investor) external;
}
