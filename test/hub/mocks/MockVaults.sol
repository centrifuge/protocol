// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Auth} from "../../../src/misc/Auth.sol";
import {D18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {IAdapter} from "../../../src/common/interfaces/IAdapter.sol";
import {MessageLib} from "../../../src/common/libraries/MessageLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IMessageHandler} from "../../../src/common/interfaces/IMessageHandler.sol";
import {RequestMessageLib} from "../../../src/common/libraries/RequestMessageLib.sol";

import "forge-std/Test.sol";

contract MockVaults is Test, Auth, IAdapter {
    using MessageLib for *;
    using CastLib for string;
    using BytesLib for bytes;
    using RequestMessageLib for *;

    IMessageHandler public handler;
    uint16 public sourceChainId;

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
            MessageLib.Request(
                poolId.raw(),
                scId.raw(),
                assetId.raw(),
                RequestMessageLib.DepositRequest({investor: investor, amount: amount}).serialize()
            ).serialize()
        );
    }

    function requestRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor, uint128 amount)
        public
    {
        handler.handle(
            sourceChainId,
            MessageLib.Request(
                poolId.raw(),
                scId.raw(),
                assetId.raw(),
                RequestMessageLib.RedeemRequest({investor: investor, amount: amount}).serialize()
            ).serialize()
        );
    }

    function cancelDepositRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public {
        handler.handle(
            sourceChainId,
            MessageLib.Request(
                poolId.raw(),
                scId.raw(),
                assetId.raw(),
                RequestMessageLib.CancelDepositRequest({investor: investor}).serialize()
            ).serialize()
        );
    }

    function cancelRedeemRequest(PoolId poolId, ShareClassId scId, AssetId assetId, bytes32 investor) public {
        handler.handle(
            sourceChainId,
            MessageLib.Request(
                poolId.raw(),
                scId.raw(),
                assetId.raw(),
                RequestMessageLib.CancelRedeemRequest({investor: investor}).serialize()
            ).serialize()
        );
    }

    function send(uint16, bytes memory data, uint256, address) external payable returns (bytes32 adapterData) {
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
        bool isIncrease,
        bool isSnapshot,
        uint64 nonce
    ) public {
        handler.handle(
            sourceChainId,
            MessageLib.UpdateHoldingAmount({
                poolId: poolId.raw(),
                scId: scId.raw(),
                assetId: assetId.raw(),
                amount: amount,
                pricePerUnit: pricePoolPerAsset.raw(),
                timestamp: 0,
                isIncrease: isIncrease,
                isSnapshot: isSnapshot,
                nonce: nonce
            }).serialize()
        );
    }

    function updateShares(
        PoolId poolId,
        ShareClassId scId,
        uint128 amount,
        bool isIssuance,
        bool isSnapshot,
        uint64 nonce
    ) public {
        handler.handle(
            sourceChainId,
            MessageLib.UpdateShares({
                poolId: poolId.raw(),
                scId: scId.raw(),
                shares: amount,
                timestamp: 0,
                isIssuance: isIssuance,
                isSnapshot: isSnapshot,
                nonce: nonce
            }).serialize()
        );
    }

    function estimate(uint16, bytes calldata, uint256 baseCost) external pure returns (uint256) {
        return baseCost;
    }

    function resetMessages() external {
        delete lastMessages;
    }

    function messageCount() external view returns (uint256) {
        return lastMessages.length;
    }

    function popMessage() external returns (bytes memory message) {
        require(lastMessages.length > 0, "mockVaults/no-msgs");

        message = lastMessages[0];

        for (uint256 i = 1; i < lastMessages.length; i++) {
            lastMessages[i - 1] = lastMessages[i];
        }

        lastMessages.pop();
    }
}
