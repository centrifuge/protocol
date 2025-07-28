// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IVaultManager} from "./IVaultManager.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

enum VaultKind {
    /// @dev Refers to AsyncVault
    Async,
    /// @dev not yet supported
    Sync,
    /// @dev Refers to SyncDepositVault
    SyncDepositAsyncRedeem
}

/// @notice Interface for the all vault contracts
/// @dev Must be implemented by all vaults
interface IVault {
    /// @notice Identifier of the Centrifuge pool
    function poolId() external view returns (PoolId);

    /// @notice Identifier of the share class of the Centrifuge pool
    function scId() external view returns (ShareClassId);

    /// @notice Returns the associated manager.
    function manager() external view returns (IVaultManager);

    /// @notice Checks whether the vault is partially (a)synchronous.
    ///
    /// @return vaultKind_ The kind of the vault
    function vaultKind() external view returns (VaultKind vaultKind_);
}
