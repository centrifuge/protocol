// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18} from "src/misc/types/D18.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";

/// -----------------------------------------------------
///  Hub Handlers
/// -----------------------------------------------------

/// @notice Interface for Hub methods called by messages
interface IHubGatewayHandler {
    /// @notice Tells that an asset was already registered in Vaults, in order to perform the corresponding register.
    function registerAsset(AssetId assetId, uint8 decimals) external;

    /// @notice Perform a deposit that was requested from Vaults.
    function depositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId, uint128 amount)
        external;

    /// @notice Perform a redeem that was requested from Vaults.
    function redeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId, uint128 amount)
        external;

    /// @notice Perform a deposit cancellation that was requested from Vaults.
    function cancelDepositRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId depositAssetId)
        external;

    /// @notice Perform a redeem cancellation that was requested from Vaults.
    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, bytes32 investor, AssetId payoutAssetId) external;

    /// @notice Update a holding by request from CAL.
    function updateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease
    ) external;

    /// @notice Increases the total issuance of shares by request from CAL.
    function increaseShareIssuance(PoolId poolId, ShareClassId scId, uint128 amount) external;

    /// @notice Decreases the total issuance of shares by request from CAL.
    function decreaseShareIssuance(PoolId poolId, ShareClassId scId, uint128 amount) external;
}

/// -----------------------------------------------------
///  Vaults Handlers
/// -----------------------------------------------------

/// @notice Interface for Vaults methods related to pools called by messages
interface IPoolManagerGatewayHandler {
    /// @notice    New pool details from an existing Centrifuge pool are added.
    /// @dev       The function can only be executed by the gateway contract.
    function addPool(PoolId poolId) external;

    /// @notice     New share class details from an existing Centrifuge pool are added.
    /// @dev        The function can only be executed by the gateway contract.
    function addShareClass(
        PoolId poolId,
        ShareClassId scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) external;

    /// @notice   Updates the tokenName and tokenSymbol of a share class token
    /// @dev      The function can only be executed by the gateway contract.
    function updateShareMetadata(PoolId poolId, ShareClassId scId, string memory tokenName, string memory tokenSymbol)
        external;

    /// @notice  Updates the price of a share class token, i.e. the factor of pool currency amount per share class token
    /// @dev     The function can only be executed by the gateway contract.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  price The price of pool currency per share class token as factor.
    /// @param  computedAt The timestamp when the price was computed
    function updatePricePoolPerShare(PoolId poolId, ShareClassId scId, uint128 price, uint64 computedAt) external;

    /// @notice  Updates the price of an asset, i.e. the factor of pool currency amount per asset unit
    /// @dev     The function can only be executed by the gateway contract.
    /// @param  poolId The pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  poolPerAsset The price of pool currency per asset unit as factor.
    /// @param  computedAt The timestamp when the price was computed
    function updatePricePoolPerAsset(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 poolPerAsset,
        uint64 computedAt
    ) external;

    /// @notice Updates the hook of a share class token
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  hook The new hook addres
    function updateShareHook(PoolId poolId, ShareClassId scId, address hook) external;

    /// @notice Updates the restrictions on a share class token for a specific user
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  update The restriction update in the form of a bytes array indicating
    ///                the restriction to be updated, the user to be updated, and a validUntil timestamp.
    function updateRestriction(PoolId poolId, ShareClassId scId, bytes memory update) external;

    /// @notice Mints share class tokens to a recipient
    /// @dev    The function can only be executed internally or by the gateway contract.
    function handleTransferShares(PoolId poolId, ShareClassId scId, address destinationAddress, uint128 amount)
        external;

    /// @notice Updates the target address. Generic update function from Hub to Vaults
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  target The target address to be called
    /// @param  update The payload to be processed by the target address
    function updateContract(PoolId poolId, ShareClassId scId, address target, bytes memory update) external;
}

/// @notice Interface for Vaults methods related to async investments called by messages
interface IRequestManagerGatewayHandler {
    /// @notice Signal from the Hub that an asynchronous investment order has been approved
    ///
    /// @dev This message needs to trigger making the asset amounts available to the pool-share-class.
    function approvedDeposits(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        D18 pricePoolPerAsset
    ) external;

    /// @notice Signal from the Hub that an asynchronous investment order has been finalized. Shares have been issued.
    ///
    /// @dev This message needs to trigger minting the new amount of shares.
    function issuedShares(PoolId poolId, ShareClassId scId, uint128 shareAmount, D18 pricePoolPerShare) external;

    /// @notice Signal from the Hub that an asynchronous redeem order has been finalized.
    ///
    /// @dev This messages needs to trigger reserving the asset amount for claims of redemptions by users.
    function revokedShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 assetAmount,
        uint128 shareAmount,
        D18 pricePoolPerShare
    ) external;

    // --- Deposits ---
    /// @notice Fulfills pending deposit requests after successful epoch execution on Hub.
    ///         The amount of shares that can be claimed by the user is minted and moved to the escrow contract.
    ///         The maxMint and claimableCancelDepositRequest bookkeeping values are updated.
    ///         The request fulfillment can be partial.
    /// @dev    The shares in the escrow are reserved for the user and are transferred to the user on deposit
    ///         and mint calls.
    /// @dev    The cancelled and fulfilled amounts are both non-zero iff the cancellation was queued.
    ///         Otherwise, either of the two must always be zero.
    function fulfillDepositRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledAssetAmount
    ) external;

    // --- Redeems ---
    /// @notice Fulfills pending redeem requests after successful epoch execution on Hub.
    ///         The amount of redeemed shares is burned. The amount of assets that can be claimed by the user in
    ///         return is locked in the escrow contract.
    ///         The maxWithdraw and claimableCancelRedeemRequest bookkeeping values are updated.
    ///         The request fulfillment can be partial.
    /// @dev    The assets in the escrow are reserved for the user and are transferred to the user on redeem
    ///         and withdraw calls.
    /// @dev    The cancelled and fulfilled amounts are both non-zero iff the cancellation was queued.
    ///         Otherwise, either of the two must always be zero.
    function fulfillRedeemRequest(
        PoolId poolId,
        ShareClassId scId,
        address user,
        AssetId assetId,
        uint128 fulfilledAssetAmount,
        uint128 fulfilledShareAmount,
        uint128 cancelledShareAmount
    ) external;
}

/// @notice Interface for Vaults methods related to epoch called by messages
interface IBalanceSheetGatewayHandler {
    function triggerIssueShares(PoolId poolId, ShareClassId scId, address to, uint128 shares) external;

    function submitQueuedShares(PoolId poolId, ShareClassId scId) external;

    function submitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId) external;

    function setQueue(PoolId poolId, ShareClassId scId, bool enabled) external;
}
