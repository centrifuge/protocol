// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IQueueManager} from "./interfaces/IQueueManager.sol";

import {TransientStorageLib} from "../../misc/libraries/TransientStorageLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {ISnapshotQueue} from "../../core/spoke/interfaces/ISnapshotQueue.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";

/// @dev minDelay can be set to a non-zero value, for cases where assets or shares can be permissionlessly modified
///      (e.g. if the on/off ramp manager is used, or if sync deposits are enabled). This prevents spam.
contract QueueManager is IQueueManager, IManagerCallFromHub {
    address public immutable envoy;
    ISpoke public immutable spoke;
    ISnapshotQueue public immutable snapshotQueue;
    IGateway public immutable gateway;

    mapping(PoolId => mapping(ShareClassId => ShareClassQueueState)) public scQueueState;

    constructor(address envoy_, ISpoke spoke_) {
        envoy = envoy_;
        spoke = spoke_;
        snapshotQueue = spoke_.snapshotQueue();
        gateway = spoke_.gateway();
    }

    //----------------------------------------------------------------------------------------------
    // Hub actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (bytes16 scId_, uint64 minDelay, uint64 extraGasLimit) = abi.decode(payload, (bytes16, uint64, uint64));
        ShareClassId scId = ShareClassId.wrap(scId_);
        ShareClassQueueState storage sc = scQueueState[poolId][scId];
        sc.minDelay = minDelay;
        sc.extraGasLimit = extraGasLimit;
        emit UpdateQueueConfig(poolId, scId, minDelay, extraGasLimit);
    }

    //----------------------------------------------------------------------------------------------
    // Sync
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IQueueManager
    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds, address refund) external payable {
        gateway.withBatch{value: msg.value}(
            abi.encodeWithSelector(QueueManager.syncCallback.selector, poolId, scId, assetIds), refund
        );
    }

    function syncCallback(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds) external {
        gateway.lockCallback();

        ShareClassQueueState storage sc = scQueueState[poolId][scId];
        require(sc.lastSync == 0 || block.timestamp >= sc.lastSync + sc.minDelay, MinDelayNotElapsed());

        for (uint256 i = 0; i < assetIds.length; i++) {
            bytes32 key = keccak256(abi.encode(poolId.raw(), scId.raw(), assetIds[i].raw()));
            if (TransientStorageLib.tloadBool(key)) continue; // Skip duplicate
            TransientStorageLib.tstore(key, true);

            // Check if valid
            (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(poolId, scId, assetIds[i]);
            if (deposits > 0 || withdrawals > 0) {
                spoke.submitQueuedAssets(poolId, scId, assetIds[i], sc.extraGasLimit, address(0));
            }
        }

        (uint128 delta,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(poolId, scId);
        bool submitShares = delta > 0 && queuedAssetCounter == 0;

        if (submitShares) {
            spoke.submitQueuedShares(poolId, scId, sc.extraGasLimit, address(0));
            sc.lastSync = uint64(block.timestamp);
        }
    }
}
