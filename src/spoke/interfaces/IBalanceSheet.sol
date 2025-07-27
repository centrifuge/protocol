// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpoke} from "./ISpoke.sol";

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {IRoot} from "../../common/interfaces/IRoot.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {IPoolEscrow} from "../../common/interfaces/IPoolEscrow.sol";
import {ISpokeMessageSender} from "../../common/interfaces/IGatewaySenders.sol";
import {IPoolEscrowProvider} from "../../common/factories/interfaces/IPoolEscrowFactory.sol";

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

interface IBalanceSheet {
    // --- Events ---
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

    // --- Errors ---
    error FileUnrecognizedParam();
    error CannotTransferFromEndorsedContract();

    function root() external view returns (IRoot);
    function spoke() external view returns (ISpoke);
    function sender() external view returns (ISpokeMessageSender);
    function poolEscrowProvider() external view returns (IPoolEscrowProvider);

    function manager(PoolId poolId, address manager) external view returns (bool);
    function queuedShares(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce);
    function queuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 increase, uint128 decrease);

    function file(bytes32 what, address data) external;

    /// @notice Deposit assets into the escrow of the pool.
    /// @param  tokenId SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported.
    function deposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external;

    /// @notice Note a deposit of assets into the escrow of the pool.
    /// @dev    Must be followed by a transfer of the equivalent amount of assets to `IBalanceSheet.escrow(poolId)`
    ///         This function is mostly useful to keep higher level integrations CEI adherent.
    /// @param  tokenId SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported.
    function noteDeposit(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external;

    /// @notice Withdraw assets from the escrow of the pool.
    /// @param  tokenId SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported.
    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount
    ) external;

    /// @notice Increase the reserved balance of the pool. These assets are removed from the available balance
    ///         and cannot be withdrawn before they are unreserved.
    ///
    ///         It is possible to reserve more than the current balance, to lock future expected assets.
    function reserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external;

    /// @notice Decrease the reserved balance of the pool. These assets are re-added to the available balance.
    function unreserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 amount) external;

    /// @notice Issue new share tokens. Increases the total issuance.
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external;

    /// @notice Revoke share tokens. Decreases the total issuance.
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external;

    /// @notice Sends the queued updated holding amount to the Hub
    function submitQueuedAssets(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 extraGasLimit) external;

    /// @notice Sends the queued updated shares changed to the Hub
    function submitQueuedShares(PoolId poolId, ShareClassId scId, uint128 extraGasLimit) external;

    /// @notice Force-transfers share tokens.
    function transferSharesFrom(
        PoolId poolId,
        ShareClassId scId,
        address sender,
        address from,
        address to,
        uint256 amount
    ) external;

    /// @notice Override the price pool per asset, to be used for any other balance sheet interactions.
    /// @dev    This can be used to note an interaction at a lower/higher price than the current one.
    ///         resetPricePoolPerAsset MUST be called after the balance sheet interactions using this price.
    function overridePricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId, D18 value) external;

    /// @notice Reset the price pool per asset.
    function resetPricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId) external;

    /// @notice Override the price pool per share, to be used for any other balance sheet interactions.
    /// @dev    This can be used to note an interaction at a lower/higher price than the current one.
    ///         resetPricePoolPerShare MUST be called after the balance sheet interactions using this price.
    function overridePricePoolPerShare(PoolId poolId, ShareClassId scId, D18 value) external;

    /// @notice Reset the price pool per share.
    function resetPricePoolPerShare(PoolId poolId, ShareClassId scId) external;

    /// @notice Returns the pool escrow.
    /// @dev    Assets for pending deposit requests are not held by the pool escrow.
    function escrow(PoolId poolId) external view returns (IPoolEscrow);

    /// @notice Returns the amount of assets that can be withdrawn from the balance sheet.
    /// @dev    Assets that are locked for redemption requests are reserved and not available for withdrawals.
    /// @param  tokenId SHOULD be 0 if depositing ERC20 assets. ERC6909 assets with tokenId=0 are not supported.
    function availableBalanceOf(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId)
        external
        view
        returns (uint128);
}
