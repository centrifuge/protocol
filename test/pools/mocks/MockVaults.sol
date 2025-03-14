// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

import {AssetId} from "src/pools/types/AssetId.sol";
import {PoolId} from "src/pools/types/PoolId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

import "forge-std/Test.sol";

contract MockVaults is Test, IAdapter {
    using MessageLib for *;
    using CastLib for string;
    using BytesLib for bytes;

    IMessageHandler public handler;
    uint32 public sourceChainId;
    bool public wasPaid;

    uint32[] public lastChainDestinations;
    bytes[] public lastMessages;

    constructor(uint32 chainId, IMessageHandler handler_) {
        handler = handler_;
        sourceChainId = chainId;
    }

    function registerAsset(AssetId assetId, string memory name, string memory symbol, uint8 decimals) public {
        handler.handle(
            sourceChainId,
            MessageLib.RegisterAsset({
                assetId: assetId.raw(),
                name: name,
                symbol: symbol.toBytes32(),
                decimals: decimals
            }).serialize()
        );
    }

    function requestDeposit(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint128 amount)
        public
    {
        handler.handle(
            sourceChainId,
            MessageLib.DepositRequest({
                poolId: poolId.raw(),
                scId: scId.raw(),
                investor: investor,
                assetId: assetId.raw(),
                amount: amount
            }).serialize()
        );
    }

    function requestRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint128 amount)
        public
    {
        handler.handle(
            sourceChainId,
            MessageLib.RedeemRequest({
                poolId: poolId.raw(),
                scId: scId.raw(),
                investor: investor,
                assetId: assetId.raw(),
                amount: amount
            }).serialize()
        );
    }

    function send(uint32 chainId, bytes memory data) external {
        assertEq(wasPaid, true, "Before sending, pay must be called with a value > 0");

        lastChainDestinations.push(chainId);

        while (data.length > 0) {
            uint16 messageLength = data.messageLength();
            bytes memory message = data.slice(0, messageLength);

            lastMessages.push(message);

            data = data.slice(messageLength, data.length - messageLength);
        }

        wasPaid = false;
    }

    function estimate(uint32, bytes calldata, uint256 baseCost) external pure returns (uint256) {
        return baseCost;
    }

    function pay(uint32, bytes calldata, address) external payable {
        wasPaid = msg.value != 0;
        payable(0).transfer(msg.value);
    }

    function resetMessages() external {
        delete lastChainDestinations;
        delete lastMessages;
    }
}
