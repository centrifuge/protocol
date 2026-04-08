// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IManifest} from "../../interfaces/ISupervisor.sol";

import {PoolId} from "../../../../core/types/PoolId.sol";
import {ShareClassId} from "../../../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../../../core/utils/interfaces/IContractUpdate.sol";

struct Slot {
    uint128 anchor;
    uint64 windowStart;
    uint64 window;
    uint128 maxDeltaBps;
}

interface ISharePriceDeltaManifest is IManifest, ITrustedContractUpdate {
    event SetConfig(PoolId indexed poolId, ShareClassId indexed scId, uint128 maxDeltaBps, uint64 window);

    error NotAuthorized();

    function contractUpdater() external view returns (address);
    function slots(PoolId poolId, ShareClassId scId)
        external
        view
        returns (uint128 anchor, uint64 windowStart, uint64 window, uint128 maxDeltaBps);
}
