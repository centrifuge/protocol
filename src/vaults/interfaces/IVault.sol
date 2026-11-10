// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";

/// @notice Implemented by all vaults.
interface IVault {
    /// @notice The pool the vault belongs to.
    function poolId() external view returns (PoolId);

    /// @notice The share class the vault issues.
    function scId() external view returns (ShareClassId);
}
