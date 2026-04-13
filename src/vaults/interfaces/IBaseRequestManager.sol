// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IBaseVault} from "./IBaseVault.sol";

import {IEscrow} from "../../misc/interfaces/IEscrow.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {IPoolEscrow} from "../../core/spoke/interfaces/IPoolEscrow.sol";
import {IRequestManager} from "../../core/interfaces/IRequestManager.sol";
import {ISpokeV3_1_0} from "../../core/spoke/legacy/interfaces/ISpokeV3_1_0.sol";

interface IBaseRequestManager is IRequestManager {
    event File(bytes32 indexed what, address data);

    error FileUnrecognizedParam();

    /// @notice Updates contract parameters of type address.
    /// @param what The bytes32 representation of 'spoke', etc.
    /// @param data The new contract address.
    function file(bytes32 what, address data) external;

    /// @notice Converts the assets value to share decimals.
    function convertToShares(IBaseVault vault, uint256 _assets) external view returns (uint256 shares);

    /// @notice Converts the shares value to assets decimals.
    function convertToAssets(IBaseVault vault, uint256 _shares) external view returns (uint256 assets);

    /// @notice Returns the timestamp of the last share price update for a vaultAddr.
    function priceLastUpdated(IBaseVault vault) external view returns (uint64 lastUpdated);

    /// @notice Returns the Spoke contract address.
    function spoke() external view returns (ISpokeV3_1_0 spoke);

    /// @notice DEPRECATED: Returns the pool escrow for the calling vault's pool.
    /// NOTE: DEPRECATED IMPLEMENTATION: This function is maintained solely for ABI backward compatibility
    ///      with deployed vaults that call this function.
    ///      Despite the misleading "globalEscrow" name, this implementation returns the pool-specific
    ///      but NOT a global escrow. The global escrow concept was deprecated in v3.1.
    function globalEscrow() external view returns (IEscrow escrow);

    /// @notice Escrow per pool. Funds are associated to a specific pool
    function poolEscrow(PoolId poolId) external view returns (IPoolEscrow);
}
