// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IOnOffRamp} from "./IOnOffRamp.sol";

import {PoolId} from "../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";

interface IOnOffRampFactory {
    event DeployOnOffRamp(PoolId indexed poolId, ShareClassId scId, address indexed manager);

    /// @notice Deploys new on-offramp manager.
    function newManager(PoolId poolId, ShareClassId scId) external returns (IOnOffRamp);
}
