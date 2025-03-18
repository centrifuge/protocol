// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

import {PoolManager} from "src/vaults/PoolManager.sol";
import {VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";

interface AdapterLike {
    function execute(bytes memory _message) external;
}

contract MockCentrifugeChain is Test {
    using CastLib for *;
    using MessageLib for *;

    IAdapter[] public adapters;
    PoolManager public poolManager;

    constructor(IAdapter[] memory adapters_, PoolManager poolManager_) {
        for (uint256 i = 0; i < adapters_.length; i++) {
            adapters.push(adapters_[i]);
        }
        poolManager = poolManager_;
    }

    function addPool(uint64 poolId) public {
        execute(MessageLib.NotifyPool({poolId: poolId}).serialize());
    }

    function unlinkVault(uint64 poolId, bytes16 trancheId, address vault) public {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);

        execute(
            MessageLib.UpdateContract({
                poolId: poolId,
                scId: trancheId,
                target: bytes32(bytes20(address(poolManager))),
                payload: MessageLib.UpdateContractVaultUpdate({
                    factory: address(0),
                    assetId: vaultDetails.assetId,
                    isLinked: false,
                    vault: vault
                }).serialize()
            }).serialize()
        );
    }

    function linkVault(uint64 poolId, bytes16 trancheId, address vault) public {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);

        execute(
            MessageLib.UpdateContract({
                poolId: poolId,
                scId: trancheId,
                target: bytes32(bytes20(address(poolManager))),
                payload: MessageLib.UpdateContractVaultUpdate({
                    factory: address(0),
                    assetId: vaultDetails.assetId,
                    isLinked: true,
                    vault: vault
                }).serialize()
            }).serialize()
        );
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

    function recoverTokens(address target, address token, uint256 tokenId, address to, uint256 amount) public {
        execute(
            MessageLib.RecoverTokens({
                target: bytes32(bytes20(target)),
                token: bytes32(bytes20(token)),
                tokenId: tokenId,
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
            AdapterLike(address(adapters[i])).execute(i == 0 ? message : proof);
        }
    }
}
