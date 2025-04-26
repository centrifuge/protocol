// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

/// @dev Solely used locally as protection against stack-too-deep
struct Prices {
    /// @dev Price of 1 asset unit per share unit
    D18 assetPerShare;
    /// @dev Price of 1 pool unit per asset unit
    D18 poolPerAsset;
    /// @dev Price of 1 pool unit per share unit
    D18 poolPerShare;
}

interface ISyncDepositValuation {
    /// @notice Returns the pool price per share for a given pool and share class, asset, and asset id.
    // The provided price is defined as POOL_UNIT/SHARE_UNIT.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @return price The pool price per share
    function pricePoolPerShare(PoolId poolId, ShareClassId scId) external view returns (D18 price);
}

interface ISharePriceProvider is ISyncDepositValuation {
    /// @notice Returns the all three prices for a given pool, share class, asset, and asset id.
    ///
    /// @param poolId The pool id
    /// @param scId The share class id
    /// @param assetId The asset id corresponding to the asset and tokenId
    /// @return priceData The asset price per share, pool price per asset, and pool price per share
    function prices(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (Prices memory priceData);
}
