// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IExecutor} from "./IExecutor.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IBalanceSheet} from "../../../core/spoke/interfaces/IBalanceSheet.sol";

interface IExecutorFactory {
    event DeployExecutor(PoolId indexed poolId, address indexed executor);

    error InvalidPoolId();

    function contractUpdater() external view returns (address);
    function balanceSheet() external view returns (IBalanceSheet);

    /// @notice Deploys a new Executor for the given pool.
    function newExecutor(PoolId poolId) external returns (IExecutor);
}
