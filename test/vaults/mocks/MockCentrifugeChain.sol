// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {d18} from "src/misc/types/D18.sol";

import {MessageType, MessageLib, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";
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

    function unlinkVault(uint64 poolId, bytes16 scId, address vault) public {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);

        execute(
            MessageLib.UpdateContract({
                poolId: poolId,
                scId: scId,
                target: bytes32(bytes20(address(poolManager))),
                payload: MessageLib.UpdateContractVaultUpdate({
                    vaultOrFactory: bytes32(bytes20(vault)),
                    assetId: vaultDetails.assetId,
                    kind: uint8(VaultUpdateKind.Unlink)
                }).serialize()
            }).serialize()
        );
    }

    function linkVault(uint64 poolId, bytes16 scId, address vault) public {
        VaultDetails memory vaultDetails = poolManager.vaultDetails(vault);

        execute(
            MessageLib.UpdateContract({
                poolId: poolId,
                scId: scId,
                target: bytes32(bytes20(address(poolManager))),
                payload: MessageLib.UpdateContractVaultUpdate({
                    vaultOrFactory: bytes32(bytes20(vault)),
                    assetId: vaultDetails.assetId,
                    kind: uint8(VaultUpdateKind.Link)
                }).serialize()
            }).serialize()
        );
    }

    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        bytes32 salt,
        address hook
    ) public {
        execute(
            MessageLib.NotifyShareClass({
                poolId: poolId,
                scId: scId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32(),
                decimals: decimals,
                salt: salt,
                hook: bytes32(bytes20(hook))
            }).serialize()
        );
    }

    function addShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public {
        execute(
            MessageLib.NotifyShareClass({
                poolId: poolId,
                scId: scId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32(),
                decimals: decimals,
                salt: keccak256(abi.encodePacked(poolId, scId)),
                hook: bytes32(bytes20(hook))
            }).serialize()
        );
    }

    function updateMember(uint64 poolId, bytes16 scId, address user, uint64 validUntil) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: scId,
                payload: MessageLib.UpdateRestrictionMember(user.toBytes32(), validUntil).serialize()
            }).serialize()
        );
    }

    function updateShareMetadata(uint64 poolId, bytes16 scId, string memory tokenName, string memory tokenSymbol)
        public
    {
        execute(
            MessageLib.UpdateShareClassMetadata({
                poolId: poolId,
                scId: scId,
                name: tokenName,
                symbol: tokenSymbol.toBytes32()
            }).serialize()
        );
    }

    function updateShareHook(uint64 poolId, bytes16 scId, address hook) public {
        execute(MessageLib.UpdateShareClassHook({poolId: poolId, scId: scId, hook: bytes32(bytes20(hook))}).serialize());
    }

    function updateSharePrice(uint64 poolId, bytes16 scId, uint128 price, uint64 computedAt) public {
        execute(
            MessageLib.NotifySharePrice({poolId: poolId, scId: scId, price: price, timestamp: computedAt}).serialize()
        );
    }

    function updateAssetPrice(uint64 poolId, bytes16 scId, uint128 assetId, uint128 price, uint64 computedAt) public {
        execute(
            MessageLib.NotifyAssetPrice({
                poolId: poolId,
                scId: scId,
                assetId: assetId,
                price: price,
                timestamp: computedAt
            }).serialize()
        );
    }

    function triggerIncreaseRedeemOrder(uint64 poolId, bytes16 scId, address investor, uint128 assetId, uint128 amount)
        public
    {
        execute(
            MessageLib.TriggerRedeemRequest({
                poolId: poolId,
                scId: scId,
                investor: investor.toBytes32(),
                assetId: assetId,
                shares: amount
            }).serialize()
        );
    }

    function incomingTransferShares(uint64 poolId, bytes16 scId, address destinationAddress, uint128 amount) public {
        execute(
            MessageLib.TransferShares({
                poolId: poolId,
                scId: scId,
                receiver: destinationAddress.toBytes32(),
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

    function freeze(uint64 poolId, bytes16 scId, address user) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: scId,
                payload: MessageLib.UpdateRestrictionFreeze(user.toBytes32()).serialize()
            }).serialize()
        );
    }

    function unfreeze(uint64 poolId, bytes16 scId, address user) public {
        execute(
            MessageLib.UpdateRestriction({
                poolId: poolId,
                scId: scId,
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
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets
    ) public {
        execute(
            MessageLib.FulfilledCancelDepositRequest({
                poolId: poolId,
                scId: scId,
                investor: investor,
                assetId: assetId,
                cancelledAmount: assets
            }).serialize()
        );
    }

    function isFulfilledCancelRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 shares
    ) public {
        execute(
            MessageLib.FulfilledCancelRedeemRequest({
                poolId: poolId,
                scId: scId,
                investor: investor,
                assetId: assetId,
                cancelledShares: shares
            }).serialize()
        );
    }

    function isFulfilledDepositRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {
        execute(
            MessageLib.FulfilledDepositRequest({
                poolId: poolId,
                scId: scId,
                investor: investor,
                assetId: assetId,
                assetAmount: assets,
                shareAmount: shares
            }).serialize()
        );
    }

    function isFulfilledRedeemRequest(
        uint64 poolId,
        bytes16 scId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {
        execute(
            MessageLib.FulfilledRedeemRequest({
                poolId: poolId,
                scId: scId,
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
