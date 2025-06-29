// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IOnOfframpManager} from "src/managers/interfaces/IOnOfframpManager.sol";

interface IOnOfframpManagerFactory {
    event DeployOnOfframpManager(PoolId indexed poolId, ShareClassId scId, address indexed manager);

    error InvalidIds();

    /// @notice Deploys new on-offramp manager.
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOfframpManager);
}
