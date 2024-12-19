// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ChainId, ShareClassId, AssetId, Ratio, ItemId} from "src/types/Domain.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {PoolId} from "src/types/PoolId.sol";

import {IItemManager} from "src/interfaces/IItemManager.sol";

enum Escrow {
    SHARE_CLASS,
    PENDING_SHARE_CLASS
}

/// @dev interface for methods that requires the pool to be unlocked
/// NOTE: They do not require a poolId parameter although they acts over an specific pool
interface IPoolUnlockedMethods {
    function allowPool(ChainId chainId) external;

    function allowShareClass(ChainId chainId, ShareClassId scId) external;

    function approveDeposit(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function approveRedemption(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function issueShares(ShareClassId id, uint128 nav) external;

    function revokeShares(ShareClassId scId, AssetId assetId, uint128 nav) external;

    function increaseItem(IItemManager im, ItemId itemId, uint128 amount) external;

    function decreaseItem(IItemManager im, ItemId itemId, uint128 amount) external;

    function updateItem(IItemManager im, ItemId itemId) external;

    function moveOut(ChainId chainId, ShareClassId scId, AssetId assetId, address receiver, uint128 assetAmount)
        external
        returns (uint128 poolAmount);
}

/// @dev interface for methods called by the gateway
interface IFromGatewayMethods {
    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, address investor, uint128 amount)
        external;

    function requestRedemption(PoolId poolId, ShareClassId scId, AssetId assetId, address investor, uint128 amount)
        external;

    function notifyLockedTokens(AssetId assetId, address recvAddr, uint128 amount) external;
}

interface IPoolManager is IPoolUnlockedMethods, IFromGatewayMethods {
    error NotAllowed();

    function createPool(IERC20Metadata currency, IShareClassManager shareClassManager) external returns (PoolId);

    function claimShares(PoolId poolId, ShareClassId scId, AssetId assetId, address investor) external;

    function claimTokens(PoolId poolId, ShareClassId scId, AssetId assetId, address investor) external;
}
