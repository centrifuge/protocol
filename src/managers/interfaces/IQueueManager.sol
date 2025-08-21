// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IQueueManager {
    error InvalidPoolId();
    error NotContractUpdater();
    error NoUpdates();

    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds) external;
}
