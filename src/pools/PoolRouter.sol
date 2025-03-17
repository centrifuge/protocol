// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {Auth} from "src/misc/Auth.sol";
import {Multicall, IMulticall} from "src/misc/Multicall.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";

import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {AccountId, newAccountId} from "src/pools/types/AccountId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";
import {IPoolManager} from "src/pools/interfaces/IPoolManager.sol";
import {IPoolRouter} from "src/pools/interfaces/IPoolRouter.sol";

contract PoolRouter is Multicall, IPoolRouter {
    IPoolManager public immutable poolManager;
    IGateway public gateway;

    constructor(IPoolManager poolManager_, IGateway gateway_) {
        poolManager = poolManager_;
        gateway = gateway_;
    }

    // --- Administration ---
    /// @inheritdoc IMulticall
    /// @notice performs a multicall but all messages sent in the process will be batched
    function multicall(bytes[] calldata data) public payable override {
        bool wasBatching = gateway.isBatching();
        if (!wasBatching) {
            gateway.startBatch();
        }

        if (poolManager.unlockedPoolId().isNull()) {
            super.multicall(data);
        } else {
            // Calling from execute will use poolManager as target
            uint256 totalBytes = data.length;
            for (uint256 i; i < totalBytes; ++i) {
                (bool success, bytes memory returnData) = address(poolManager).call(data[i]);
                if (!success) {
                    uint256 length = returnData.length;
                    require(length != 0, CallFailedWithEmptyRevert());

                    assembly ("memory-safe") {
                        revert(add(32, returnData), length)
                    }
                }
            }
        }

        if (!wasBatching) {
            gateway.topUp{value: msg.value}();
            gateway.endBatch();
        }
    }

    /// @inheritdoc IPoolRouter
    function execute(PoolId poolId, bytes[] calldata data) external payable {
        poolManager.unlock(poolId, msg.sender);

        multicall(data);

        poolManager.lock();
    }

    /// @inheritdoc IPoolRouter
    function createPool(AssetId currency, IShareClassManager shareClassManager)
        external
        payable
        returns (PoolId poolId)
    {
        return poolManager.createPool(msg.sender, currency, shareClassManager);
    }

    /// @inheritdoc IPoolRouter
    function claimDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        payable
        protected
    {
        _pay();
        poolManager.claimDeposit(poolId, scId, assetId, investor);
    }

    /// @inheritdoc IPoolRouter
    function claimRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor)
        external
        payable
        protected
    {
        _pay();
        poolManager.claimRedeem(poolId, scId, assetId, investor);
    }

    /// @notice Send native tokens to the gateway for transaction payment if it's not in a multicall.
    function _pay() internal {
        if (!gateway.isBatching()) {
            gateway.topUp{value: msg.value}();
        }
    }
}
