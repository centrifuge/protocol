// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";

interface IHubGuardianActions {
    /// @notice Creates a new pool.
    /// @param currency The pool currency. Usually an AssetId identifying by a ISO4217 code.
    function createPool(PoolId poolId, address admin, AssetId currency) external payable;
}
