// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpoke} from "./ISpoke.sol";
import {IPoolEscrow} from "./IPoolEscrow.sol";
import {IEndorsements} from "./IEndorsements.sol";

import {D18} from "../../../misc/types/D18.sol";

import {ISpokeMessageSender} from "../../messaging/interfaces/IGatewaySenders.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";
import {IBatchedMulticall} from "../../utils/interfaces/IBatchedMulticall.sol";
import {IPoolEscrowProvider} from "../factories/interfaces/IPoolEscrowFactory.sol";

struct ShareQueueAmount {
    // Net queued shares
    uint128 delta;
    // Whether the net queued shares lead to an issuance or revocation
    bool isPositive;
    // Number of queued asset IDs for this share class
    uint32 queuedAssetCounter;
    // Nonce for share + asset messages to the hub
    uint64 nonce;
}

struct AssetQueueAmount {
    uint128 deposits;
    uint128 withdrawals;
}

interface IBalanceSheet is IBatchedMulticall {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, address data);
    event UpdateManager(PoolId indexed poolId, address who, bool canManage);
    event Withdraw(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePoolPerAsset
    );
    event Deposit(PoolId indexed poolId, ShareClassId indexed scId, address asset, uint256 tokenId, uint128 amount);
    event NoteDeposit(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        D18 pricePoolPerAsset
    );
    event Issue(PoolId indexed poolId, ShareClassId indexed scId, address to, D18 pricePoolPerShare, uint128 shares);
    event Revoke(PoolId indexed poolId, ShareClassId indexed scId, address from, D18 pricePoolPerShare, uint128 shares);
    event TransferSharesFrom(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address sender,
        address indexed from,
        address to,
        uint256 amount
    );
    event SubmitQueuedShares(PoolId indexed poolId, ShareClassId indexed scId, ISpokeMessageSender.UpdateData data);
    event SubmitQueuedAssets(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        ISpokeMessageSender.UpdateData data,
        D18 pricePoolPerAsset
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error FileUnrecognizedParam();
    error CannotTransferFromEndorsedContract();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'spoke', 'sender', 'gateway', 'poolEscrowProvider'
    /// @param data The new address
    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // Management functions
    //----------------------------------------------------------------------------------------------

    /// @notice Deposit assets into the escrow of the pool
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID (SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported)
    /// @param amount The amount to deposit
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external payable;

    /// @notice Note a deposit of assets into the escrow of the pool.
    /// @dev    Must be followed by a transfer of the equivalent amount of assets to `IBalanceSheet.escrow(poolId)`
    ///         This function is mostly useful to keep higher level integrations CEI adherent.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param  tokenId SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported.
    /// @param amount The amount to deposit
    function noteDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        payable;

    /// @notice Withdraw assets from the escrow of the pool
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID (SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported)
    /// @param receiver The address to receive the withdrawn assets
    /// @param amount The amount to withdraw
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external payable;

    /// @notice Increase the reserved balance of the pool
    /// @dev These assets are removed from the available balance and cannot be withdrawn before they are unreserved.
    ///      It is possible to reserve more than the current balance, to lock future expected assets
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID
    /// @param amount The amount to reserve
    function reserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external payable;

    /// @notice Decrease the reserved balance of the pool
    /// @dev These assets are re-added to the available balance
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param tokenId The token ID
    /// @param amount The amount to unreserve
    function unreserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount)
        external
        payable;

    /// @notice Issue new share tokens
    /// @dev Increases the total issuance
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param to The address to issue shares to
    /// @param shares The number of shares to issue
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external payable;

    /// @notice Revoke share tokens
    /// @dev Decreases the total issuance
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param shares The number of shares to revoke
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external payable;

    /// @notice Sends the queued updated holding amount to the Hub
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param extraGasLimit Extra gas limit for cross-chain execution
    /// @param refund Address to receive excess gas refund
    function submitQueuedAssets(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 extraGasLimit,
        address refund
    ) external payable;

    /// @notice Sends the queued updated shares changed to the Hub
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param extraGasLimit Extra gas limit for cross-chain execution
    /// @param refund Address to receive excess gas refund
    function submitQueuedShares(PoolId poolId, ShareClassId scId, uint128 extraGasLimit, address refund)
        external
        payable;

    /// @notice Force-transfers share tokens
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param sender The address initiating the transfer
    /// @param from The address to transfer from
    /// @param to The address to transfer to
    /// @param amount The amount to transfer
    function transferSharesFrom(
        PoolId poolId,
        ShareClassId scId,
        address sender,
        address from,
        address to,
        uint256 amount
    ) external payable;

    /// @notice Override the price pool per asset, to be used for any other balance sheet interactions.
    /// @dev    This can be used to note an interaction at a lower/higher price than the current one.
    ///         resetPricePoolPerAsset MUST be called after the balance sheet interactions using this price.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param value The price to override with
    function overridePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 value) external payable;

    /// @notice Reset the price pool per asset.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    function resetPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external payable;

    /// @notice Override the price pool per share, to be used for any other balance sheet interactions.
    /// @dev    This can be used to note an interaction at a lower/higher price than the current one.
    ///         resetPricePoolPerShare MUST be called after the balance sheet interactions using this price.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param value The price to override with
    function overridePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 value) external payable;

    /// @notice Reset the price pool per share.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    function resetPricePoolPerShare(PoolId poolId, ShareClassId scId) external payable;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the spoke contract
    /// @return The spoke contract instance
    function spoke() external view returns (ISpoke);

    /// @notice Returns the message sender contract
    /// @return The message sender contract instance
    function sender() external view returns (ISpokeMessageSender);

    /// @notice Returns the endorsements contract
    /// @return The endorsements contract instance
    function endorsements() external view returns (IEndorsements);

    /// @notice Returns the pool escrow provider
    /// @return The pool escrow provider instance
    function poolEscrowProvider() external view returns (IPoolEscrowProvider);

    /// @notice Checks if an address is a manager for a pool
    /// @param poolId The pool identifier
    /// @param manager The address to check
    /// @return Whether the address is a manager
    function manager(PoolId poolId, address manager) external view returns (bool);

    /// @notice Returns the queued shares for a share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @return delta Net queued shares
    /// @return isPositive Whether the net queued shares lead to an issuance or revocation
    /// @return queuedAssetCounter Number of queued asset IDs for this share class
    /// @return nonce Nonce for share + asset messages to the hub
    function queuedShares(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce);

    /// @notice Returns the queued assets for a share class and asset
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return increase Queued deposits
    /// @return decrease Queued withdrawals
    function queuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 increase, uint128 decrease);

    /// @notice Returns the pool escrow.
    /// @dev    Assets for pending deposit requests are not held by the pool escrow.
    /// @param poolId The pool identifier
    /// @return The pool escrow instance
    function escrow(PoolId poolId) external view returns (IPoolEscrow);

    /// @notice Returns the amount of assets that can be withdrawn from the balance sheet.
    /// @dev    Assets that are locked for redemption requests are reserved and not available for withdrawals.
    /// @param  poolId The pool identifier
    /// @param scId The share class identifier
    /// @param asset The asset address
    /// @param  tokenId SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported.
    /// @return The available balance
    function availableBalanceOf(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        external
        view
        returns (uint128);
}
