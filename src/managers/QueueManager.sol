// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IQueueManager} from "./interfaces/IQueueManager.sol";

import {CastLib} from "../misc/libraries/CastLib.sol";
import {BitmapLib} from "../misc/libraries/BitmapLib.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";
import {TransientStorageLib} from "../misc/libraries/TransientStorageLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {IBalanceSheet} from "../spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "../spoke/interfaces/IUpdateContract.sol";
import {UpdateContractMessageLib, UpdateContractType} from "../spoke/libraries/UpdateContractMessageLib.sol";

/// @dev minDelay can be set to a non-zero value, for cases where assets or shares can be permissionlessly modified
///      (e.g. if the on/off ramp manager is used, or if sync deposits are enabled). This prevents spam.
contract QueueManager is IQueueManager, IUpdateContract {
    using CastLib for *;
    using BitmapLib for *;

    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    mapping(PoolId => mapping(ShareClassId => ShareClassQueueState)) public scQueueState;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId, ShareClassId scId, bytes calldata payload) external {
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
    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds) external {
        ShareClassQueueState storage sc = scQueueState[poolId][scId];
        require(
            sc.lastSync == 0 || sc.minDelay == 0 || block.timestamp >= sc.lastSync + sc.minDelay, MinDelayNotElapsed()
        );

        (uint128 delta,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(poolId, scId);
        require(delta > 0 || queuedAssetCounter > 0, NoUpdates());

        require(assetIds.length <= 256, TooManyAssets()); // Bitmap limit

        // Deduplicate and validate using bitmap for valid indices
        uint256 validBitmap = 0; // Each bit represents if that index is valid
        uint256 validCount = 0;

        for (uint256 i = 0; i < assetIds.length; i++) {
            bytes32 key = keccak256(abi.encode(scId.raw(), assetIds[i].raw()));
            if (TransientStorageLib.tloadBool(key)) {
                continue; // Skip duplicate
            }
            TransientStorageLib.tstore(key, true);

            // Check if valid
            (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetIds[i]);
            if (deposits > 0 || withdrawals > 0) {
                validBitmap = validBitmap.withBit(i, true);
                validCount++;
            }
        }

        // Build exactly-sized array
        bool submitShares = delta > 0 && validCount >= queuedAssetCounter;
        bytes[] memory cs = new bytes[](validCount + (submitShares ? 1 : 0));

        uint256 csIndex = 0;
        for (uint256 i = 0; i < assetIds.length; i++) {
            if (validBitmap.getBit(i)) {
                // Check if index i is valid
                cs[csIndex++] = abi.encodeWithSelector(
                    balanceSheet.submitQueuedAssets.selector, poolId, scId, assetIds[i], sc.extraGasLimit
                );
            }
        }

        if (submitShares) {
            cs[validCount] =
                abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, poolId, scId, sc.extraGasLimit);
            sc.lastSync = uint64(block.timestamp);
        }

        IMulticall(address(balanceSheet)).multicall(cs);
    }
}
