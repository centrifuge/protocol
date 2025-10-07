// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IQueueManager} from "./interfaces/IQueueManager.sol";

import {Auth} from "../../misc/Auth.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {BitmapLib} from "../../misc/libraries/BitmapLib.sol";
import {TransientStorageLib} from "../../misc/libraries/TransientStorageLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {IGateway} from "../../core/interfaces/IGateway.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IBalanceSheet} from "../../core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../../core/interfaces/IContractUpdate.sol";

import {UpdateContractMessageLib, UpdateContractType} from "../../libraries/UpdateContractMessageLib.sol";

/// @dev minDelay can be set to a non-zero value, for cases where assets or shares can be permissionlessly modified
///      (e.g. if the on/off ramp manager is used, or if sync deposits are enabled). This prevents spam.
contract QueueManager is Auth, IQueueManager, ITrustedContractUpdate {
    using CastLib for *;
    using BitmapLib for *;

    IGateway public immutable gateway;
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    mapping(PoolId => mapping(ShareClassId => ShareClassQueueState)) public scQueueState;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_, address deployer) Auth(deployer) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
        gateway = balanceSheet_.gateway();
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotContractUpdater());

        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));
        if (kind == uint8(UpdateContractType.UpdateQueue)) {
            UpdateContractMessageLib.UpdateContractUpdateQueue memory m =
                UpdateContractMessageLib.deserializeUpdateContractUpdateQueue(payload);
            ShareClassQueueState storage sc = scQueueState[poolId][scId];
            sc.minDelay = m.minDelay;
            sc.extraGasLimit = m.extraGasLimit;
            emit UpdateQueueConfig(poolId, scId, m.minDelay, m.extraGasLimit);
        } else {
            revert UnknownUpdateContractType();
        }
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
        require(
            sc.lastSync == 0 || sc.minDelay == 0 || block.timestamp >= sc.lastSync + sc.minDelay, MinDelayNotElapsed()
        );

        (uint128 delta,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(poolId, scId);
        uint256 validCount = 0;
        for (uint256 i = 0; i < assetIds.length; i++) {
            bytes32 key = keccak256(abi.encode(scId.raw(), assetIds[i].raw()));
            if (TransientStorageLib.tloadBool(key)) continue; // Skip duplicate
            TransientStorageLib.tstore(key, true);

            // Check if valid
            (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetIds[i]);
            if (deposits > 0 || withdrawals > 0) {
                balanceSheet.submitQueuedAssets(poolId, scId, assetIds[i], sc.extraGasLimit, address(0));
                validCount++;
            }
        }

        bool submitShares = delta > 0 && validCount == queuedAssetCounter;
        require(validCount > 0 || submitShares, NoUpdates());

        if (submitShares) {
            balanceSheet.submitQueuedShares(poolId, scId, sc.extraGasLimit, address(0));
            sc.lastSync = uint64(block.timestamp);
        }
    }
}
