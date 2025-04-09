// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";

import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";

/// @dev Solely used locally as protection against stack-too-deep
struct SyncPriceData {
    /// @dev Price of 1 asset unit per share unit
    D18 assetPerShare;
    /// @dev Price of 1 pool unit per asset unit
    D18 poolPerAsset;
    /// @dev Price of 1 pool unit per share unit
    D18 poolPerShare;
}

interface ISyncRequests is ISyncDepositManager, IUpdateContract {
    event SetValuation(uint64 indexed poolId, bytes16 indexed scId, address asset, uint256 tokenId, address oracle);

    error ExceedsMaxDeposit();
    error AssetNotAllowed();

    /// @notice Sets the valuation for a specific pool, share class and asset.
    ///
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param asset The address of the asset
    /// @param tokenId The asset token id, i.e. 0 for ERC20, or the token id for ERC6909
    /// @param valuation The address of the valuation contract
    function setValuation(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address valuation) external;

    /// @notice Returns the price per share for a given pool, share class, asset, and asset id. The provided price is
    /// defined as ASSET_UNIT/SHARE_UNIT.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id for which we want to know the ASSET_UNIT/SHARE_UNIT price
    /// @return price The asset price per share
    function priceAssetPerShare(uint64 poolId, bytes16 scId, uint128 assetId) external view returns (D18 price);

    /// @notice Returns the all three prices for a given pool, share class, asset, and asset id.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id corresponding to the asset and tokenId
    /// @param asset The address of the asset corresponding to the assetId
    /// @param tokenId The asset token id, i.e. 0 for ERC20, or the token id for ERC6909
    /// @return priceData The asset price per share, pool price per asset, and pool price per share
    function prices(uint64 poolId, bytes16 scId, uint128 assetId, address asset, uint256 tokenId)
        external
        view
        returns (SyncPriceData memory priceData);
}
