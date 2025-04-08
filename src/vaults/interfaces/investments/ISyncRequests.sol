// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";

interface ISyncRequests is ISyncDepositManager {
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
    /// @return computedAt The timestamp at which the price was computed
    function priceAssetPerShare(uint64 poolId, bytes16 scId, uint128 assetId, bool checkValidity)
        external
        view
        returns (D18 price, uint64 computedAt);
}
