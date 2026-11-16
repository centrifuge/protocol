// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

/// @title  IVaultPosition
/// @notice The pool and share class a vault says it was built for. The spoke handler reads it when `DeployAndLink`
///         registers a vault, so a vault can only be registered under the position it names.
/// @dev    A vault is registered at the address a factory returns for the pool that sent the message, and the factory
///         is whatever address that message names. The vault's own position is the one thing such a factory cannot
///         choose for it: it is fixed when the vault is built.
interface IVaultPosition {
    /// @notice The pool the vault was built for
    function poolId() external view returns (PoolId);

    /// @notice The share class the vault was built for
    function scId() external view returns (ShareClassId);
}
