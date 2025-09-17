// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {ISnapshotHook} from "../../../src/common/interfaces/ISnapshotHook.sol";

contract MockSnapshotHook is ISnapshotHook {
    mapping(PoolId => mapping(ShareClassId => mapping(uint16 centrifugeId => uint256 counter))) public synced;
    mapping(
        PoolId
            => mapping(
                ShareClassId
                    => mapping(uint16 fromCentrifugeId => mapping(uint16 toCentrifugeId => uint256 amountTransferred))
            )
    ) public transfers;

    function onSync(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external {
        synced[poolId][scId][centrifugeId]++;
    }

    function onTransfer(
        PoolId poolId,
        ShareClassId scId,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external {
        transfers[poolId][scId][fromCentrifugeId][toCentrifugeId] += sharesTransferred;
    }
}
