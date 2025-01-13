// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {ChainId, Ratio} from "src/types/Domain.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {GlobalAddress} from "src/types/GlobalAddress.sol";
import {ItemId} from "src/types/ItemId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";

import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {IItemManager} from "src/interfaces/IItemManager.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

enum Escrow {
    SHARE_CLASS,
    PENDING_SHARE_CLASS
}

/// @dev interface for methods that requires the pool to be unlocked
/// NOTE: They do not require a poolId parameter although they acts over an specific pool
interface IPoolUnlockedMethods {
    function notifyPool(ChainId chainId) external;

    function notifyShareClass(ChainId chainId, ShareClassId scId) external;

    function notifyAllowedAsset(ChainId chainId, ShareClassId scId, AssetId assetId, bool isAllowed) external;

    function allowAsset(ShareClassId scId, AssetId assetId, bool isAllowed) external;

    function approveDeposit(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function approveRedeem(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function issueShares(ShareClassId id, uint128 nav) external;

    function revokeShares(ShareClassId scId, AssetId assetId, uint128 nav) external;

    function increaseItem(IItemManager im, ItemId itemId, IERC7726 valuation, uint128 amount) external;

    function decreaseItem(IItemManager im, ItemId itemId, IERC7726 valuation, uint128 amount) external;

    function updateItem(IItemManager im, ItemId itemId) external;

    function unlockTokens(ShareClassId scId, AssetId assetId, GlobalAddress receiver, uint128 assetAmount) external;
}

/// @dev interface for methods called by the gateway
interface IFromGatewayMethods {
    function notifyRegisteredAsset(AssetId assetId) external;

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor, uint128 amount)
        external;

    function requestRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor, uint128 amount)
        external;

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;

    function notifyLockedTokens(AssetId assetId, address recvAddr, uint128 amount) external;
}

interface IPoolManager is IPoolUnlockedMethods, IFromGatewayMethods {
    error NotAllowed();

    function createPool(IERC20Metadata currency, IShareClassManager shareClassManager) external returns (PoolId);

    function claimShares(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;

    function claimTokens(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;
}
