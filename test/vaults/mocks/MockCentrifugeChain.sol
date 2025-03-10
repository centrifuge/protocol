// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";

import "forge-std/Test.sol";

interface AdapterLike {
    function execute(bytes memory _message) external;
}

contract MockCentrifugeChain is Test {
    using CastLib for *;
    using MessageLib for *;

    address[] public adapters;

    constructor(address[] memory adapters_) {
        for (uint256 i = 0; i < adapters_.length; i++) {
            adapters.push(adapters_[i]);
        }
    }

    function addPool(uint64 poolId) public {
        execute(MessageLib.NotifyPool({poolId: poolId}).serialize());
    }

    function batchAddPoolAllowAsset(uint64 poolId, uint128 assetId) public {
        bytes memory _addPool = MessageLib.NotifyPool({poolId: poolId}).serialize();
        bytes memory _allowAsset =
            MessageLib.AllowAsset({poolId: poolId, scId: bytes16(0), assetId: assetId}).serialize();

        bytes memory _message = abi.encodePacked(_addPool, _allowAsset);
        execute(_message);
    }

    function allowAsset(uint64 poolId, uint128 assetId) public {
        execute(MessageLib.AllowAsset({poolId: poolId, scId: bytes16(0), assetId: assetId}).serialize());
    }

    function disallowAsset(uint64 poolId, uint128 assetId) public {
        execute(MessageLib.DisallowAsset({poolId: poolId, scId: bytes16(0), assetId: assetId}).serialize());
    }

    function addTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public {
        execute(
            MessageLib.NotifyShareClass({
                poolId: poolId,
                scId: trancheId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32(),
                decimals: decimals,
                salt: salt,
                hook: bytes32(bytes20(hook))
            }).serialize()
        );
    }

    function addTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public {
        execute(
            MessageLib.NotifyShareClass({
                poolId: poolId,
                scId: trancheId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32(),
                decimals: decimals,
                salt: keccak256(abi.encodePacked(poolId, trancheId)),
                hook: bytes32(bytes20(hook))
            }).serialize()
        );
    }

    function updateMember(uint64 poolId, bytes16 trancheId, address user, uint64 validUntil) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: trancheId,
                payload: MessageLib.UpdateRestrictionMember(user.toBytes32(), validUntil).serialize()
            }).serialize()
        );
    }

    function updateTrancheMetadata(uint64 poolId, bytes16 trancheId, string memory tokenName, string memory tokenSymbol)
        public
    {
        execute(
            MessageLib.UpdateShareClassMetadata({
                poolId: poolId,
                scId: trancheId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32()
            }).serialize()
        );
    }

    function updateTrancheHook(uint64 poolId, bytes16 trancheId, address hook) public {
        execute(
            MessageLib.UpdateShareClassHook({poolId: poolId, scId: trancheId, hook: bytes32(bytes20(hook))}).serialize()
        );
    }

    function updateTranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId, uint128 price, uint64 computedAt)
        public
    {
        execute(
            MessageLib.UpdateShareClassPrice({
                poolId: poolId,
                scId: trancheId,
                assetId: assetId,
                price: price,
                timestamp: computedAt
            }).serialize()
        );
    }

    function updateCentrifugeGasPrice(uint128 price, uint64 computedAt) public {
        execute(MessageLib.UpdateGasPrice({price: price, timestamp: computedAt}).serialize());
    }

    function triggerIncreaseRedeemOrder(
        uint64 poolId,
        bytes16 trancheId,
        address investor,
        uint128 assetId,
        uint128 amount
    ) public {
        execute(
            MessageLib.TriggerRedeemRequest({
                poolId: poolId,
                scId: trancheId,
                investor: investor.toBytes32(),
                assetId: assetId,
                shares: amount
            }).serialize()
        );
    }

    function incomingTransferTrancheTokens(uint64 poolId, bytes16 trancheId, address destinationAddress, uint128 amount)
        public
    {
        execute(
            MessageLib.TransferShares({
                poolId: poolId,
                scId: trancheId,
                recipient: destinationAddress.toBytes32(),
                amount: amount
            }).serialize()
        );
    }

    function incomingScheduleUpgrade(address target) public {
        execute(MessageLib.ScheduleUpgrade({target: bytes32(bytes20(target))}).serialize());
    }

    function incomingCancelUpgrade(address target) public {
        execute(MessageLib.CancelUpgrade({target: bytes32(bytes20(target))}).serialize());
    }

    function freeze(uint64 poolId, bytes16 trancheId, address user) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: trancheId,
                payload: MessageLib.UpdateRestrictionFreeze(user.toBytes32()).serialize()
            }).serialize()
        );
    }

    function unfreeze(uint64 poolId, bytes16 trancheId, address user) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: trancheId,
                payload: MessageLib.UpdateRestrictionUnfreeze(user.toBytes32()).serialize()
            }).serialize()
        );
    }

    function recoverTokens(address target, address token, address to, uint256 amount) public {
        execute(
            MessageLib.RecoverTokens({
                target: bytes32(bytes20(target)),
                token: bytes32(bytes20(token)),
                to: bytes32(bytes20(to)),
                amount: amount
            }).serialize()
        );
    }

    function isFulfilledCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets
    ) public {
        execute(
            MessageLib.FulfilledCancelDepositRequest({
                poolId: poolId,
                scId: trancheId,
                investor: investor,
                assetId: assetId,
                cancelledAmount: assets
            }).serialize()
        );
    }

    function isFulfilledCancelRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 shares
    ) public {
        execute(
            MessageLib.FulfilledCancelRedeemRequest({
                poolId: poolId,
                scId: trancheId,
                investor: investor,
                assetId: assetId,
                cancelledShares: shares
            }).serialize()
        );
    }

    function isFulfilledDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {
        execute(
            MessageLib.FulfilledDepositRequest({
                poolId: poolId,
                scId: trancheId,
                investor: investor,
                assetId: assetId,
                assetAmount: assets,
                shareAmount: shares
            }).serialize()
        );
    }

    function isFulfilledRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {
        execute(
            MessageLib.FulfilledRedeemRequest({
                poolId: poolId,
                scId: trancheId,
                investor: investor,
                assetId: assetId,
                assetAmount: assets,
                shareAmount: shares
            }).serialize()
        );
    }

    function execute(bytes memory message) public {
        bytes memory proof = MessageLib.MessageProof({hash: keccak256(message)}).serialize();
        for (uint256 i = 0; i < adapters.length; i++) {
            AdapterLike(adapters[i]).execute(i == 0 ? message : proof);
        }
    }
}
