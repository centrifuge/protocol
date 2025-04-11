// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";

/// @dev Solely used locally as protection against stack-too-deep
struct Prices {
    /// @dev Price of 1 asset unit per share unit
    D18 assetPerShare;
    /// @dev Price of 1 pool unit per asset unit
    D18 poolPerAsset;
    /// @dev Price of 1 pool unit per share unit
    D18 poolPerShare;
}

interface ISharePriceProvider {
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
        returns (Prices memory priceData);
}
