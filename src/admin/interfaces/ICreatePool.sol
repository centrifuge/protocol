// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";

interface ICreatePool {
    /// @notice Creates a new pool
    /// @param poolId The unique identifier for the pool
    /// @param admin The address that will be the pool administrator
    /// @param currency The pool currency, usually an AssetId identifying by a ISO4217 code
    function createPool(PoolId poolId, address admin, AssetId currency) external payable;
}
