// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IQueueManager} from "./interfaces/IQueueManager.sol";

import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {IBalanceSheet} from "../spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "../spoke/interfaces/IUpdateContract.sol";

import {console2} from "forge-std/console2.sol";
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
    }

    mapping(PoolId => mapping(ShareClassId => ShareClassState)) public sc;

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

        // TODO: allow updating extraGasLimit ?
        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));
        if (kind == uint8(UpdateContractType.UpdateQueue)) {
            UpdateContractMessageLib.UpdateContractUpdateQueue memory m =
                UpdateContractMessageLib.deserializeUpdateContractUpdateQueue(payload);
            ShareClassState storage sc_ = sc[poolId][scId];
            sc_.minDelay = m.minDelay;
            emit UpdateMinDelay(poolId, scId, m.minDelay);
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
        ShareClassState storage sc_ = sc[poolId][scId];
        require(sc_.lastSync == 0 || sc_.minDelay == 0 || block.timestamp >= sc_.lastSync + sc_.minDelay);

        (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce) =
            balanceSheet.queuedShares(poolId, scId);
        require(delta > 0 || queuedAssetCounter > 0, NoUpdates());

        bool submitShares = delta > 0 && assetIds.length >= queuedAssetCounter;
        uint256 submissions = MathLib.min(assetIds.length, queuedAssetCounter);
        bytes[] memory cs = new bytes[](submitShares ? submissions + 1 : submissions);
        for (uint256 i; i < submissions; i++) {
            cs[i] = abi.encodeWithSelector(balanceSheet.submitQueuedAssets.selector, poolId, scId, assetIds[i], 0);
        }

        if (submitShares) {
            cs[submissions] = abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, poolId, scId, 0);
        }
        sc_.lastSync = uint64(block.timestamp);

        IMulticall(address(balanceSheet)).multicall(cs);
    }
}
