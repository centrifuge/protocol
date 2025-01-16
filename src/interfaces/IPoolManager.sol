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

enum AccountType {
    ASSET,
    EQUITY,
    LOSS,
    GAIN
}

/// @dev interface for methods that requires the pool to be unlocked
/// NOTE: They do not require a poolId parameter although they acts over an specific pool
interface IPoolUnlockedMethods {
    function notifyPool(ChainId chainId) external;

    function notifyShareClass(ChainId chainId, ShareClassId scId) external;

    function notifyAllowedAsset(ChainId chainId, ShareClassId scId, AssetId assetId, bool isAllowed) external;

    function setPoolMetadata(bytes calldata metadata) external;

    function setPoolAdmin(address newAdmin, bool canManage) external;

    function allowInvestorAsset(AssetId assetId, bool isAllowed) external;

    function allowHoldingAsset(AssetId assetId, bool isAllowed) external;

    function addShareClass(bytes calldata data) external returns (ShareClassId);

    function approveDeposit(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function approveRedeem(ShareClassId scId, AssetId assetId, Ratio approvalRatio) external;

    function issueShares(ShareClassId id, uint128 nav) external;

    function revokeShares(ShareClassId scId, AssetId assetId, uint128 nav) external;

    function createItem(IItemManager im, IERC7726 valuation, AccountId[] memory accounts, bytes calldata data)
        external;

    function closeItem(IItemManager im, ItemId itemId, bytes calldata data) external;

    function increaseItem(IItemManager im, ItemId itemId, IERC7726 valuation, uint128 amount) external;

    function decreaseItem(IItemManager im, ItemId itemId, IERC7726 valuation, uint128 amount) external;

    function updateItem(IItemManager im, ItemId itemId) external;

    function updateItemValuation(IItemManager im, ItemId itemId, IERC7726 valuation) external;

    function setItemAccountId(IItemManager im, ItemId itemId, AccountId accountId) external;

    function updateEntry(AccountId credit, AccountId debit, uint128 amount) external;

    function unlockTokens(ShareClassId scId, AssetId assetId, GlobalAddress receiver, uint128 assetAmount) external;
}

/// @dev interface for methods called by the gateway
interface IFromGatewayMethods {
    /// @notice Dispatched when an action that requires to be called from the gateway is calling from somebody else.
    error NotGateway();

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
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    function file(bytes32 what, address data) external;

    function createPool(IERC20Metadata currency, IShareClassManager shareClassManager) external returns (PoolId);

    function claimShares(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;

    function claimTokens(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;
}
