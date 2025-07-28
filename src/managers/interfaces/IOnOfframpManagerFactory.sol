// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOnOfframpManager} from "src/managers/interfaces/IOnOfframpManager.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

interface IOnOfframpManagerFactory {
    event DeployOnOfframpManager(PoolId indexed poolId, ShareClassId scId, address indexed manager);

    error InvalidIds();

    /// @notice Deploys new on-offramp manager.
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOfframpManager);
}
