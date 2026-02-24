// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IWeirollExecutor} from "./IWeirollExecutor.sol";

import {PoolId} from "../../../core/types/PoolId.sol";

interface IWeirollExecutorFactory {
    event DeployWeirollExecutor(PoolId indexed poolId, address indexed executor);

    error InvalidPoolId();

    /// @notice Deploys new weiroll executor.
    function newWeirollExecutor(PoolId poolId) external returns (IWeirollExecutor);
}
