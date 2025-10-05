// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

interface IFeeHook {
    /// @notice Accrue the fee amount for a specific pool and share class.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    function accrue(PoolId poolId, ShareClassId scId) external;

    /// @notice Returns the accrued fees, denominated in pool units.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @return poolAmount The accrued fee amount in pool units
    function accrued(PoolId poolId, ShareClassId scId) external view returns (uint128 poolAmount);
}
