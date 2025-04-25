// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";

import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {ISharePriceProvider} from "src/vaults/interfaces/investments/ISharePriceProvider.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

interface ISyncRequests is ISyncDepositManager, ISharePriceProvider, IUpdateContract {
    event SetValuation(
        PoolId indexed poolId, ShareClassId indexed scId, address asset, uint256 tokenId, address oracle
    );
    event SetMaxReserve(
        PoolId indexed poolId, ShareClassId indexed scId, address asset, uint256 tokenId, uint128 maxReserve
    );

    error ExceedsMaxDeposit();
    error ExceedsMaxMint();
    error AssetNotAllowed();
    error VaultDoesNotExist();
    error VaultAlreadyExists();
    error ShareTokenDoesNotExist();
    error AssetMismatch();

    /// @notice Sets the valuation for a specific pool, share class and asset.
    ///
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param asset The address of the asset
    /// @param tokenId The asset token id, i.e. 0 for ERC20, or the token id for ERC6909
    /// @param valuation The address of the valuation contract
    function setValuation(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, address valuation)
        external;

    /// @notice Sets the max reserve for a specific pool, share class and asset.
    ///
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param asset The address of the asset
    /// @param tokenId The asset token id, i.e. 0 for ERC20, or the token id for ERC6909
    /// @param maxReserve The amount of maximum reserve
    function setMaxReserve(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, uint128 maxReserve)
        external;
}
