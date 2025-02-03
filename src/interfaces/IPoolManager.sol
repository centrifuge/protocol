// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ChainId} from "src/types/ChainId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {GlobalAddress} from "src/types/GlobalAddress.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {D18} from "src/types/D18.sol";

import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
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

/// @dev Interface for methods that requires the pool to be unlocked
/// NOTE: They do not require a poolId parameter although they acts over an specific pool
interface IPoolUnlockedMethods {
    /// @notice Dispatched whem a holding asset is disallowed but the asset is still allowed for investor usage.
    error InvestorAssetStillAllowed();

    function notifyPool(ChainId chainId) external;

    function notifyShareClass(ChainId chainId, ShareClassId scId) external;

    function notifyAllowedAsset(ShareClassId scId, AssetId assetId) external;

    function setPoolMetadata(bytes calldata metadata) external;

    function setPoolAdmin(address newAdmin, bool canManage) external;

    function allowInvestorAsset(AssetId assetId, bool isAllowed) external;

    function allowHoldingAsset(AssetId assetId, bool isAllowed) external;

    function addShareClass(bytes calldata data) external returns (ShareClassId);

    function approveDeposits(ShareClassId scId, AssetId paymetAssetId, D18 approvalRatio) external;

    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, D18 approvalRatio) external;

    function issueShares(ShareClassId id, AssetId depositAssetId, D18 navPerShare) external;

    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare) external;

    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, AccountId[] memory accounts)
        external;

    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) external;

    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) external;

    function updateHolding(ShareClassId scId, AssetId assetId) external;

    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external;

    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external;

    function updateEntry(AccountId credit, AccountId debit, uint128 amount) external;

    function unlockTokens(ShareClassId scId, AssetId assetId, GlobalAddress receiver, uint128 assetAmount) external;
}

/// @dev interface for methods called by the gateway
interface IFromGatewayMethods {
    /// @notice Dispatched when an action that requires to be called from the gateway is calling from somebody else.
    error NotGateway();

    function handleRegisteredAsset(AssetId assetId, bytes calldata name, bytes32 symbol, uint8 decimals) external;

    function requestDeposit(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        GlobalAddress investor,
        uint128 amount
    ) external;

    function requestRedeem(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        GlobalAddress investor,
        uint128 amount
    ) external;

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId depositAssetId, GlobalAddress investor)
        external;
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, GlobalAddress investor)
        external;

    function handleLockedTokens(address receiver, AssetId assetId, uint128 amount) external;
}

interface IPoolManager is IPoolUnlockedMethods, IFromGatewayMethods {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    function file(bytes32 what, address data) external;

    function createPool(AssetId currency, IShareClassManager shareClassManager) external returns (PoolId);

    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;

    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, GlobalAddress investor) external;
}
