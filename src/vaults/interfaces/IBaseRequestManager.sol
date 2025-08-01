// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IBaseVault} from "./IBaseVault.sol";

import {IEscrow} from "../../misc/interfaces/IEscrow.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {IPoolEscrow} from "../../common/interfaces/IPoolEscrow.sol";
import {IRequestManager} from "../../common/interfaces/IRequestManager.sol";

import {ISpoke} from "../../spoke/interfaces/ISpoke.sol";
import {IVaultManager} from "../../spoke/interfaces/IVaultManager.sol";

interface IBaseRequestManager is IVaultManager, IRequestManager {
    event File(bytes32 indexed what, address data);

    error FileUnrecognizedParam();

    /// @notice Updates contract parameters of type address.
    /// @param what The bytes32 representation of 'gateway' or 'spoke'.
    /// @param data The new contract address.
    function file(bytes32 what, address data) external;

    /// @notice Converts the assets value to share decimals.
    function convertToShares(IBaseVault vault, uint256 _assets) external view returns (uint256 shares);

    /// @notice Converts the shares value to assets decimals.
    function convertToAssets(IBaseVault vault, uint256 _shares) external view returns (uint256 assets);

    /// @notice Returns the timestamp of the last share price update for a vaultAddr.
    function priceLastUpdated(IBaseVault vault) external view returns (uint64 lastUpdated);

    /// @notice Returns the Spoke contract address.
    function spoke() external view returns (ISpoke spoke);

    /// @notice The global escrow used for funds that are not yet free to be used for a specific pool
    function globalEscrow() external view returns (IEscrow escrow);

    /// @notice Escrow per pool. Funds are associated to a specific pool
    function poolEscrow(PoolId poolId) external view returns (IPoolEscrow);
}
