// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {AssetId} from "src/types/AssetId.sol";
import {PoolId} from "src/types/PoolId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";

import {CastLib} from "src/libraries/CastLib.sol";
import {BytesLib} from "src/libraries/BytesLib.sol";

import {IMessageHandler} from "src/interfaces/IMessageHandler.sol";
import {IRouter} from "src/Gateway.sol"; // TODO: Fix me

contract MockCentrifugeVaults is Test, IRouter {
    using CastLib for string;

    IMessageHandler public handler;

    uint32 public lastChainId;
    bytes public lastMessage;

    constructor(IMessageHandler handler_) {
        handler = handler_;
    }

    function registerAsset(AssetId assetId, string calldata name, string calldata symbol, uint8 decimals) public {
        handler.handle(abi.encodePacked(assetId.raw(), name.stringToBytes128(), symbol.toBytes32(), decimals));
    }

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint128 amount)
        public
    {
        handler.handle(abi.encodePacked(poolId.raw(), scId.raw(), assetId.raw(), investor, amount));
    }

    function send(uint32 chainId, bytes calldata message) external {
        lastChainId = chainId;
        lastMessage = message;
    }
}
