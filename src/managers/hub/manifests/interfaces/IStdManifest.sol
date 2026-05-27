// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IManifest} from "../../interfaces/ISupervisor.sol";
import {IHub} from "../../../../core/hub/interfaces/IHub.sol";
import {IShareClassManager} from "../../../../core/hub/interfaces/IShareClassManager.sol";
import {IMultiAdapter} from "../../../../core/messaging/interfaces/IMultiAdapter.sol";
import {PoolId} from "../../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../../core/types/ShareClassId.sol";

interface IStdManifest is IManifest {
    error NotAuthorized();
    error CannotRemoveSupervisor();
    error AdapterMismatch();

    function hub() external view returns (IHub);
    function supervisor() external view returns (address);
    function grantManagerDelay() external view returns (uint48);
    function timelock() external view returns (uint48);
    function thresholdPerSecond() external view returns (uint128);
    function shareClassManager() external view returns (IShareClassManager);
    function multiAdapter() external view returns (IMultiAdapter);
    function lastPriceUpdate(PoolId poolId, ShareClassId scId) external view returns (uint48);
}
