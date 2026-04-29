// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IManifest} from "../../interfaces/ISupervisor.sol";
import {IShareClassManager} from "../../../../core/hub/interfaces/IShareClassManager.sol";
import {PoolId} from "../../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../../core/types/ShareClassId.sol";

interface IPriceManifest is IManifest {
    error NotAuthorized();
    error CannotRemoveSupervisor();

    function supervisor() external view returns (address);
    function grantManagerDelay() external view returns (uint48);
    function additionalDelay() external view returns (uint48);
    function thresholdPerSecond() external view returns (uint128);
    function shareClassManager() external view returns (IShareClassManager);
    function lastPriceUpdate(PoolId poolId, ShareClassId scId) external view returns (uint48);
}
