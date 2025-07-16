// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {PoolId} from "centrifuge-v3/src/common/types/PoolId.sol";
import {ShareClassId} from "centrifuge-v3/src/common/types/ShareClassId.sol";

import {IOnOfframpManager} from "centrifuge-v3/src/managers/interfaces/IOnOfframpManager.sol";

interface IOnOfframpManagerFactory {
    event DeployOnOfframpManager(PoolId indexed poolId, ShareClassId scId, address indexed manager);

    error InvalidIds();

    /// @notice Deploys new on-offramp manager.
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOfframpManager);
}
