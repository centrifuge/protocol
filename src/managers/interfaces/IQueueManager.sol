// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IQueueManager {
    event UpdateMinDelay(PoolId indexed poolId, ShareClassId indexed scId, uint64 newMinDelay);

    error NotContractUpdater();
    error NoUpdates();
    error MinDelayNotElapsed();
    error DuplicateAsset();
    error NoUpdateForAsset();

    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds) external;
}
