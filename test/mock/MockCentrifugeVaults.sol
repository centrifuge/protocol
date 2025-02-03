// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {AssetId} from "src/types/AssetId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {IPoolManager} from "src/interfaces/IPoolManager.sol"; // TODO: remove import
import {ShareClassId} from "src/types/ShareClassId.sol";

contract MockCentrifugeVaults is Test {
    IPoolManager poolManager; // TODO: change to gateway when it's implemented

    constructor(IPoolManager poolManager_) {
        poolManager = poolManager_;
    }

    function registerAsset(AssetId assetId, bytes calldata name, bytes32 symbol, uint8 decimals) public {
        // TODO: Create message and send message to the Gateway
        // But by now, we bypass the gateway:
        poolManager.handleRegisteredAsset(assetId, name, symbol, decimals);
    }

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId depositAssetId, bytes32 investor, uint128 amount)
        public
    {
        // TODO: Create message and send message to the Gateway
        // But by now, we bypass the gateway:
        poolManager.requestDeposit(poolId, scId, depositAssetId, investor, amount);
    }
}
