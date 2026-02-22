// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IExecutor} from "./IExecutor.sol";

import {PoolId} from "../../../core/types/PoolId.sol";

interface IExecutorFactory {
    event DeployExecutor(PoolId indexed poolId, address indexed executor);

    error InvalidPoolId();

    /// @notice Deploys new executor.
    function newExecutor(PoolId poolId) external returns (IExecutor);
}
