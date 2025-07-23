// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOnOfframpManager} from "./IOnOfframpManager.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IOnOfframpManagerFactory {
    event DeployOnOfframpManager(PoolId indexed poolId, ShareClassId scId, address indexed manager);

    error InvalidIds();

    /// @notice Deploys new on-offramp manager.
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOfframpManager);
}
