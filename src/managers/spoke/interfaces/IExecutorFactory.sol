// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IExecutor} from "./IExecutor.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {IGateway} from "../../../core/messaging/interfaces/IGateway.sol";
import {IBalanceSheet} from "../../../core/spoke/interfaces/IBalanceSheet.sol";

interface IExecutorFactory {
    event DeployExecutor(PoolId indexed poolId, address indexed executor);

    error AlreadyDeployed();
    error InvalidPoolId();

    function contractUpdater() external view returns (address);
    function balanceSheet() external view returns (IBalanceSheet);
    function gateway() external view returns (IGateway);

    /// @notice Returns the executor deployed for a given pool, or address(0) if none.
    function executors(PoolId poolId) external view returns (address);

    /// @notice Deploys a new Executor for the given pool.
    function newExecutor(PoolId poolId) external returns (IExecutor);
}
