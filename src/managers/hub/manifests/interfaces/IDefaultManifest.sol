// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../../core/utils/interfaces/IContractUpdate.sol";

import {IManifest} from "../../interfaces/ISupervisor.sol";

struct PriceDeltaSlot {
    uint128 anchor;
    uint64 windowStart;
    uint64 window;
    uint128 maxDeltaBps;
}

interface IDefaultManifest is IManifest, ITrustedContractUpdate {
    event SetPriceDeltaConfig(
        PoolId indexed poolId, ShareClassId indexed scId, uint128 maxDeltaBps, uint64 window
    );

    error NotAuthorized();
    error DeltaExceeded(uint256 anchor, uint256 newVal, uint256 maxDeltaBps);
    error CannotRemoveSupervisor();
    error CannotRemoveSelf();

    function supervisor() external view returns (address);
    function contractUpdater() external view returns (address);
    function grantManagerDelay() external view returns (uint48);
    function priceDeltaSlots(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 anchor, uint64 windowStart, uint64 window, uint128 maxDeltaBps);
}
