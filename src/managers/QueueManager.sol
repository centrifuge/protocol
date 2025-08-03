// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {IBalanceSheet} from "../spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "../spoke/interfaces/IUpdateContract.sol";

/// @dev minDelay can be set to a non-zero value, for cases where assets or shares can be permissionlessly modified
///      (e.g. if the on/off ramp manager is used, or if sync deposits are enabled). This prevents spam.
contract QueueManager is IUpdateContract {
    using CastLib for *;

    error InvalidPoolId();
    error NotSpoke();
    error NoUpdates();

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
    function update(PoolId poolId_, ShareClassId scId_, bytes calldata payload) external {
        require(msg.sender == contractUpdater, NotSpoke());

        // TODO: allow updating lastSync, extraGasLimit
    }

    //----------------------------------------------------------------------------------------------
    // Sync
    //----------------------------------------------------------------------------------------------

    /// @dev It is the caller's responsibility to ensure all asset IDs have a non-zero delta,
    ///      and `sync` is called n times up until the moment all asset IDs are included, and the shares
    ///      get synced as well.
    ///
    ///      TODO: how to prevent spam for invalid asset IDs? Without checking the delta is non-negative,
    ///      since this would open up a DoS vector.
    function sync(PoolId poolId, ShareClassId scId, AssetId[] calldata assetIds) external {
        ShareClassState storage sc_ = sc[poolId][scId];
        require(sc_.lastSync == 0 || sc_.minDelay == 0 || block.timestamp >= sc_.lastSync + sc_.minDelay);

        (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce) =
            balanceSheet.queuedShares(poolId, scId);
        require(delta > 0 || queuedAssetCounter > 0, NoUpdates());

        bool submitShares = assetIds.length >= queuedAssetCounter;
        uint256 submissions = MathLib.min(assetIds.length, queuedAssetCounter);
        bytes[] memory cs = new bytes[](submitShares ? submissions + 1 : submissions);
        for (uint256 i; i < submissions; i++) {
            cs[i] = abi.encodeWithSelector(balanceSheet.submitQueuedAssets.selector, poolId, scId, assetIds[i], 0);
        }

        if (submitShares) {
            cs[cs.length] = abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, poolId, scId, 0);
        }
        sc_.lastSync = uint64(block.timestamp);

        IMulticall(address(balanceSheet)).multicall(cs);
    }
}
