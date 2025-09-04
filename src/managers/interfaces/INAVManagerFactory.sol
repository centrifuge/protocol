// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {INAVManager} from "./INAVManager.sol";

import {PoolId} from "../../common/types/PoolId.sol";

interface INAVManagerFactory {
    event DeployNavManager(PoolId indexed poolId, address indexed manager);

    error InvalidPoolId();

    /// @notice Deploys new merkle proof manager.
    function newManager(PoolId poolId) external returns (INAVManager);
}
