// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IQueueManager} from "./interfaces/IQueueManager.sol";

import {CastLib} from "../misc/libraries/CastLib.sol";
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

    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    struct ShareClassState {
        uint64 minDelay;
        uint64 lastSync;
        uint128 extraGasLimit;
    }

    mapping(PoolId => mapping(ShareClassId => ShareClassState)) public shareClassState;

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
            ShareClassState storage sc = shareClassState[poolId][scId];
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

    /// @dev It is the caller's responsibility to ensure all asset IDs have a non-zero delta,
    ///      and `sync` is called n times up until the moment all asset IDs are included, and the shares
    ///      get synced as well.
    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds) external {
        ShareClassState storage sc = shareClassState[poolId][scId];
        require(
            sc.lastSync == 0 || sc.minDelay == 0 || block.timestamp >= sc.lastSync + sc.minDelay, MinDelayNotElapsed()
        );

        (uint128 delta,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(poolId, scId);
        require(delta > 0 || queuedAssetCounter > 0, NoUpdates());

        bool maybeSubmitShares = delta > 0 && assetIds.length >= queuedAssetCounter;
        uint256 submissions = assetIds.length;
        uint32 actualSubmissions = 0;
        bytes[] memory cs = new bytes[](maybeSubmitShares ? submissions + 1 : submissions);

        for (uint256 i; i < submissions; i++) {
            require(
                TransientStorageLib.tloadBool(keccak256(abi.encode("assetSeen", assetIds[i]))) == false,
                DuplicateAsset()
            );
            (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetIds[i]);
            if (deposits == 0 && withdrawals == 0) {
                // noop by just reading a property
                // doing a noop call instead of reverting, to prevent DoS
                cs[i] = abi.encodeWithSelector(balanceSheet.root.selector);
            } else {
                cs[i] = abi.encodeWithSelector(
                    balanceSheet.submitQueuedAssets.selector, poolId, scId, assetIds[i], sc.extraGasLimit
                );
                actualSubmissions++;
            }
            TransientStorageLib.tstore(keccak256(abi.encode("assetSeen", assetIds[i])), true);
        }

        if (maybeSubmitShares) {
            if (actualSubmissions < queuedAssetCounter) {
                // We didn't actually submit all queued assets, so don't submit shares
                cs[submissions] = abi.encodeWithSelector(balanceSheet.root.selector);
            } else {
                cs[submissions] =
                    abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, poolId, scId, sc.extraGasLimit);
                sc.lastSync = uint64(block.timestamp);
            }
        }

        IMulticall(address(balanceSheet)).multicall(cs);
    }
}
