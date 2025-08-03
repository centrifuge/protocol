// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {IBalanceSheet} from "../spoke/interfaces/IBalanceSheet.sol";
import {IUpdateContract} from "../spoke/interfaces/IUpdateContract.sol";

/// @dev minDelay can be set to a non-zero value, for cases where assets or shares can be permissionlessly modified
///      (e.g. if the on/off ramp manager is used, or if sync deposits are enabled). This prevents spam.
contract QueueManager {
    using CastLib for *;

    error InvalidPoolId();
    error NotSpoke();
    error NoUpdates();

    PoolId public immutable poolId;
    ShareClassId public immutable scId;
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    uint64 public minDelay;
    uint64 public lastSync;

    constructor(PoolId poolId_, ShareClassId scId_, address contractUpdater_, IBalanceSheet balanceSheet_) {
        poolId = poolId_;
        scId = scId_;
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
    }

    //----------------------------------------------------------------------------------------------
    // Owner actions
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId_, ShareClassId scId_, bytes calldata payload) external {
        require(poolId == poolId_, InvalidPoolId());
        require(msg.sender == contractUpdater, NotSpoke());

        // TODO: allow updating lastSync, extraGasLimit
    }

    //----------------------------------------------------------------------------------------------
    // Sync
    //----------------------------------------------------------------------------------------------

    function sync(uint32 maxAssetSubmissions) external {
        require(lastSync == 0 || minDelay == 0 || block.timestamp >= lastSync + minDelay);

        (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce) =
            balanceSheet.queuedShares(poolId, scId);
        require(delta > 0 || queuedAssetCounter > 0, NoUpdates());

        bool submitShares = maxAssetSubmissions >= queuedAssetCounter;
        uint256 submissions = MathLib.min(maxAssetSubmissions, queuedAssetCounter);
        bytes[] memory cs = new bytes[](submitShares ? submissions + 1 : submissions);

        for (uint256 i; i < submissions; i++) {
            cs[i + 1] = abi.encodeWithSelector(balanceSheet.submitQueuedAssets.selector, poolId, scId, assetId, 0);
        }

        if (submitShares) {
            cs[cs.length] = abi.encodeWithSelector(balanceSheet.submitQueuedShares.selector, poolId, scId, 0);
        }

        IMulticall(address(balanceSheet)).multicall(cs);

        lastSync = block.timestamp;
    }

    function sync() external {
        // TODO: maxNumbSubmissions = queuedAssetCount
    }
}

contract SyncManagerFactory is ISyncManagerFactory {
    address public immutable contractUpdater;
    IBalanceSheet public immutable balanceSheet;

    constructor(address contractUpdater_, IBalanceSheet balanceSheet_) {
        contractUpdater = contractUpdater_;
        balanceSheet = balanceSheet_;
    }

    /// @inheritdoc ISyncManagerFactory
    function newManager(PoolId poolId, ShareClassId scId) external returns (ISyncManager) {
        require(address(balanceSheet.spoke().shareToken(poolId, scId)) != address(0), InvalidIds());

        SyncManager manager = new SyncManager{salt: keccak256(abi.encode(poolId.raw(), scId.raw()))}(
            poolId, scId, contractUpdater, balanceSheet
        );

        emit DeploySyncManager(poolId, scId, address(manager));
        return ISyncManager(manager);
    }
}
