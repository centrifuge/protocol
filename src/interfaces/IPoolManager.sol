// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ShareClassId} from "src/types/ShareClassId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {D18} from "src/types/D18.sol";

import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

/// @notice AssetManager accounts identifications used by the PoolManager
enum EscrowId {
    /// @notice Represents the escrow for undeployed capital in the share class.
    /// Contains the already invested but not yet approved funds.
    PENDING_SHARE_CLASS,
    /// @notice Represents the escrow for deployed capital in the share class.
    /// Contains the already invested and approved funds.
    SHARE_CLASS
}

/// @notice Account types used by PoolManager
enum AccountType {
    /// @notice Debit normal account for tracking assets
    ASSET,
    /// @notice Credit normal account for tracking equities
    EQUITY,
    /// @notice Credit normal account for tracking losses
    LOSS,
    /// @notice Credit normal account for tracking profits
    GAIN
}

/// @notice Interface for methods that requires the pool to be unlocked
/// They do not require a poolId parameter, all acts over the unlocked pool
interface IPoolUnlockedMethods {
    /// @notice Dispatched whem a holding asset is disallowed but the asset is still allowed for investor usage.
    error InvestorAssetStillAllowed();

    /// @notice Notify to a CV instance that a new pool is available
    /// @param chainId Chain where CV instance lives
    function notifyPool(uint32 chainId) external;

    /// @notice Notify to a CV instance that a new share class is available
    /// @param chainId Chain where CV instance lives
    function notifyShareClass(uint32 chainId, ShareClassId scId) external;

    /// @notice Notify to a CV instance that a new asset in a share class is available for investing
    /// @dev Note: the chainId is retriver from the assetId
    function notifyAllowedAsset(ShareClassId scId, AssetId assetId) external;

    /// @notice attach custom data to a pool
    function setPoolMetadata(bytes calldata metadata) external;

    /// @notice Allow/disallow an account to interact as pool admin
    function allowPoolAdmin(address account, bool allow) external;

    /// @notice Allow/disallow an asset for holdings
    function allowHoldingAsset(AssetId assetId, bool allow) external;

    /// @notice Allow/disallow an asset for investment
    function allowInvestorAsset(AssetId assetId, bool allow) external;

    /// @notice Add a new share class to the pool
    /// @return The new share class Id
    function addShareClass(bytes calldata data) external returns (ShareClassId);

    /// @notice Approves a percentage of all deposit requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param paymentAssetId Identifier of the asset locked for the deposit request
    /// @param valuation Used to transform between payment assets and pool currency
    function approveDeposits(ShareClassId scId, AssetId paymentAssetId, D18 approvalRatio, IERC7726 valuation)
        external;

    /// @notice Approves a percentage of all redemption requests for the given triplet of pool id, share class id and
    /// deposit asset id.
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    function approveRedeems(ShareClassId scId, AssetId payoutAssetId, D18 approvalRatio) external;

    /// @notice Emits new shares for the given identifier based on the provided NAV per share.
    /// @param depositAssetId Identifier of the deposit asset for which shares should be issued
    /// @param navPerShare Total value of assets of the share class per share
    function issueShares(ShareClassId id, AssetId depositAssetId, D18 navPerShare) external;

    /// @notice Take back shares for the given identifier based on the provided NAV per share.
    /// deposit asset id.
    /// @param payoutAssetId Identifier of the asset for which all requests want to exchange their share class tokens
    /// @param navPerShare Total value of assets of the share class per share
    /// @param valuation Used to transform between payout assets and pool currency
    function revokeShares(ShareClassId scId, AssetId payoutAssetId, D18 navPerShare, IERC7726 valuation) external;

    /// @notice Create a new holding associated to the asset in a share class.
    /// @param valuation Used to transform between payment assets and pool currency
    /// @param accounts Associated accounting accounts to this holding
    function createHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, AccountId[] memory accounts)
        external;

    /// @notice Increase the amount of a holding.
    /// @param valuation Used to transform between payment assets and pool currency
    function increaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) external;

    /// @notice Decrease the amount of a holding.
    /// @param valuation Used to transform between payment assets and pool currency
    function decreaseHolding(ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount) external;

    /// @notice Updates the pool currency value of this holding based of the associated valuation.
    function updateHolding(ShareClassId scId, AssetId assetId) external;

    /// @notice Updates the valuation used by a holding
    /// @param valuation Used to transform between payment assets and pool currency
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IERC7726 valuation) external;

    /// @notice Set an account of a holding.
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, AccountId accountId) external;

    /// @notice Adds a double accounting entry.
    /// @param credit Account to add credit
    /// @param debit Account to add debit
    function updateEntry(AccountId credit, AccountId debit, uint128 amount) external;

    /// @notice Unlock tokens from a share class escrow in CV side.
    /// @param scId share class Id associated to the escrow from where unlock the tokens
    /// @param receiver Address in CV where to deposit the unlocked tokens
    /// @dev Note: the chainId is retriver from the assetId
    function unlockTokens(ShareClassId scId, AssetId assetId, bytes32 receiver, uint128 assetAmount) external;
}

/// @dev interface for methods called by the gateway
interface IFromGatewayMethods {
    /// @notice Dispatched when an action that requires to be called from the gateway is calling from somebody else.
    error NotGateway();

    function handleRegisteredAsset(AssetId assetId, bytes calldata name, bytes32 symbol, uint8 decimals) external;

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId depositAssetId, bytes32 investor, uint128 amount)
        external;

    function requestRedeem(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, bytes32 investor, uint128 amount)
        external;

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId depositAssetId, bytes32 investor)
        external;
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, bytes32 investor) external;

    function handleLockedTokens(address receiver, AssetId assetId, uint128 amount) external;
}

interface IPoolManager is IPoolUnlockedMethods, IFromGatewayMethods {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 what, address addr);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    function file(bytes32 what, address data) external;

    function createPool(AssetId currency, IShareClassManager shareClassManager) external returns (PoolId);

    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external;

    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) external;
}
