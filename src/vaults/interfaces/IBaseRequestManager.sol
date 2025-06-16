// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IEscrow} from "src/misc/interfaces/IEscrow.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {IPoolEscrow} from "src/common/interfaces/IPoolEscrow.sol";

import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IVaultManager} from "src/spoke/interfaces/IVaultManager.sol";
import {IRequestManager} from "src/spoke/interfaces/IRequestManager.sol";

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
