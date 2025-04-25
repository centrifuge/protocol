// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";

import "forge-std/Test.sol";

contract MockVaults is Test, Auth, IAdapter {
    using MessageLib for *;
    using CastLib for string;
    using BytesLib for bytes;

    IMessageHandler public handler;
    uint16 public sourceChainId;

    uint32[] public lastChainDestinations;
    bytes[] public lastMessages;

    constructor(uint16 centrifugeId, IMessageHandler handler_) Auth(msg.sender) {
        handler = handler_;
        sourceChainId = centrifugeId;
    }

    function registerAsset(AssetId assetId, uint8 decimals) public {
        handler.handle(
            sourceChainId, MessageLib.RegisterAsset({assetId: assetId.raw(), decimals: decimals}).serialize()
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

    function send(uint16 centrifugeId, bytes memory data, uint256, address)
        external
        payable
        returns (bytes32 adapterData)
    {
        lastChainDestinations.push(centrifugeId);

        while (data.length > 0) {
            uint16 messageLength = data.messageLength();
            bytes memory message = data.slice(0, messageLength);

            lastMessages.push(message);

            data = data.slice(messageLength, data.length - messageLength);
        }

        adapterData = bytes32("");
    }

    function updateHoldingAmount(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        uint128 amount,
        D18 pricePoolPerAsset,
        bool isIncrease
    ) public {
        handler.handle(
            sourceChainId,
            MessageLib.UpdateHoldingAmount({
                poolId: poolId.raw(),
                scId: scId.raw(),
                assetId: assetId.raw(),
                who: bytes32(0),
                amount: amount,
                pricePerUnit: pricePoolPerAsset.raw(),
                timestamp: 0,
                isIncrease: isIncrease
            }).serialize()
        );
    }

    function updateShares(PoolId poolId, ShareClassId scId, uint128 amount, bool isIssuance) public {
        handler.handle(
            sourceChainId,
            MessageLib.UpdateShares({
                poolId: poolId.raw(),
                scId: scId.raw(),
                shares: amount,
                timestamp: 0,
                isIssuance: isIssuance
            }).serialize()
        );
    }

    function estimate(uint16, bytes calldata, uint256 baseCost) external pure returns (uint256) {
        return baseCost;
    }

    function resetMessages() external {
        delete lastChainDestinations;
        delete lastMessages;
    }

    function messageCount() external view returns (uint256) {
        return lastMessages.length;
    }

    function popMessage() external returns (bytes memory) {
        require(lastMessages.length > 0, "mockVaults/no-msgs");

        bytes memory popped = lastMessages[lastMessages.length - 1];
        lastMessages.pop();
        return popped;
    }
}
