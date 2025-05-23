// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {D18, d18} from "src/misc/types/D18.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IVaultMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IPoolEscrow} from "src/spoke/interfaces/IEscrow.sol";
import {IPoolEscrowProvider} from "src/spoke/interfaces/factories/IPoolEscrowFactory.sol";

struct ShareQueueAmount {
    // Net queued shares
    uint128 delta;
    // Whether the net queued shares lead to an issuance or revocation
    bool isPositive;
    // Number of queued asset IDs for this share class
    uint32 queuedAssetCounter;
    // Nonce for share + asset messages to the hub
    // TODO: update to uint88
    uint88 nonce;
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
    event Deposit(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        uint128 amount,
        D18 pricePoolPerAsset
    );
    event Issue(PoolId indexed poolId, ShareClassId indexed scId, address to, D18 pricePoolPerShare, uint128 shares);
    event Revoke(PoolId indexed poolId, ShareClassId indexed scId, address from, D18 pricePoolPerShare, uint128 shares);

    // --- Errors ---
    error FileUnrecognizedParam();
    error CannotTransferFromEndorsedContract();

    function root() external view returns (IRoot);
    function spoke() external view returns (ISpoke);
    function sender() external view returns (IVaultMessageSender);
    function poolEscrowProvider() external view returns (IPoolEscrowProvider);

    function manager(PoolId poolId, address manager) external view returns (bool);
    function queueEnabled(PoolId poolId, ShareClassId scId) external view returns (bool);
    function queuedShares(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint88 nonce);
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

    /// @notice Issue new share tokens. Increases the total issuance.
    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares) external;

    /// @notice Revoke share tokens. Decreases the total issuance.
    function revoke(PoolId poolId, ShareClassId scId, uint128 shares) external;

    /// @notice Force-transfers share tokens.
    function transferSharesFrom(PoolId poolId, ShareClassId scId, address from, address to, uint256 amount) external;

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
