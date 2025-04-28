// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";

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

interface ISyncRequestManager is ISyncDepositManager, ISyncDepositValuation, IUpdateContract {
    event SetValuation(PoolId indexed poolId, ShareClassId indexed scId, address valuation);
    event SetMaxReserve(
        PoolId indexed poolId, ShareClassId indexed scId, address asset, uint256 tokenId, uint128 maxReserve
    );

    error ExceedsMaxMint();
    error VaultDoesNotExist();
    error VaultAlreadyExists();
    error ShareTokenDoesNotExist();
    error AssetMismatch();

    /// @notice Sets the valuation for a specific pool and share class.
    ///
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param valuation The address of the valuation contract
    function setValuation(PoolId poolId, ShareClassId scId, address valuation) external;

    /// @notice Sets the max reserve for a specific pool, share class and asset.
    ///
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param asset The address of the asset
    /// @param tokenId The asset token id, i.e. 0 for ERC20, or the token id for ERC6909
    /// @param maxReserve The amount of maximum reserve
    function setMaxReserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 maxReserve)
        external;

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
