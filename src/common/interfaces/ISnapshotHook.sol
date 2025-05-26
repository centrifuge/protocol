// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

interface ISnapshotHook {
    /// @notice Callback on snapshot.
    function onSnapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external;
}
