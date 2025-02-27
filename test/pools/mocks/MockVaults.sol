// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";

import {AssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";

import {IMessageHandler} from "src/pools/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/pools/Gateway.sol";

import "forge-std/Test.sol";

contract MockVaults is Test, IAdapter {
    using CastLib for string;

    IMessageHandler public handler;

    uint32[] public lastChainDestinations;
    bytes[] public lastMessages;

    constructor(IMessageHandler handler_) {
        handler = handler_;
    }

    function registerAsset(AssetId assetId, string memory name, string memory symbol, uint8 decimals) public {
        handler.handle(
            MessageLib.serialize(
                MessageLib.RegisterAsset({
                    assetId: assetId.raw(),
                    name: name,
                    symbol: symbol.toBytes32(),
                    decimals: decimals
                })
            )
        );
    }

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint128 amount)
        public
    {
        handler.handle(
            MessageLib.serialize(
                MessageLib.DepositRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    amount: amount
                })
            )
        );
    }

    function requestRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint128 amount)
        public
    {
        handler.handle(
            MessageLib.serialize(
                MessageLib.RedeemRequest({
                    poolId: poolId.raw(),
                    scId: scId.raw(),
                    investor: investor,
                    assetId: assetId.raw(),
                    amount: amount
                })
            )
        );
    }

    function send(uint32 chainId, bytes calldata message) external {
        lastChainDestinations.push(chainId);
        lastMessages.push(message);
    }

    function resetMessages() external {
        delete lastChainDestinations;
        delete lastMessages;
    }
}
