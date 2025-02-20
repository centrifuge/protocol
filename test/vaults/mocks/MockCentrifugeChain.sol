// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MessagesLib} from "src/vaults/libraries/MessagesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/vaults/libraries/BytesLib.sol";
import {Domain} from "src/vaults/interfaces/IPoolManager.sol";
import {RestrictionUpdate} from "src/vaults/interfaces/token/IRestrictionManager.sol";
import "forge-std/Test.sol";

interface AdapterLike {
    function execute(bytes memory _message) external;
}

contract MockCentrifugeChain is Test {
    using CastLib for *;

    address[] public adapters;

    constructor(address[] memory adapters_) {
        for (uint256 i = 0; i < adapters_.length; i++) {
            adapters.push(adapters_[i]);
        }
    }

    function addAsset(uint128 assetId, address asset) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.AddAsset), assetId, asset);
        _execute(_message);
    }

    function addPool(uint64 poolId) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.AddPool), poolId);
        _execute(_message);
    }

    function batchAddPoolAllowAsset(uint64 poolId, uint128 assetId) public {
        bytes memory _addPool = abi.encodePacked(uint8(MessagesLib.Call.AddPool), poolId);
        bytes memory _allowAsset = abi.encodePacked(uint8(MessagesLib.Call.AllowAsset), poolId, assetId);

        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.Batch), uint16(_addPool.length), _addPool, uint16(_allowAsset.length), _allowAsset
        );
        _execute(_message);
    }

    function allowAsset(uint64 poolId, uint128 assetId) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.AllowAsset), poolId, assetId);
        _execute(_message);
    }

    function disallowAsset(uint64 poolId, uint128 assetId) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.DisallowAsset), poolId, assetId);
        _execute(_message);
    }

    function addTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals,
        address hook
    ) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.AddTranche),
            poolId,
            trancheId,
            _toBytes128(tokenName),
            tokenSymbol.toBytes32(),
            decimals,
            hook
        );
        _execute(_message);
    }

    function updateMember(uint64 poolId, bytes16 trancheId, address user, uint64 validUntil) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.UpdateRestriction),
            poolId,
            trancheId,
            uint8(RestrictionUpdate.UpdateMember),
            user.toBytes32(),
            validUntil
        );
        _execute(_message);
    }

    function updateTrancheMetadata(uint64 poolId, bytes16 trancheId, string memory tokenName, string memory tokenSymbol)
        public
    {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.UpdateTrancheMetadata),
            poolId,
            trancheId,
            _toBytes128(tokenName),
            tokenSymbol.toBytes32()
        );
        _execute(_message);
    }

    function updateTrancheHook(uint64 poolId, bytes16 trancheId, address hook) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.UpdateTrancheHook), poolId, trancheId, hook);
        _execute(_message);
    }

    function updateTranchePrice(uint64 poolId, bytes16 trancheId, uint128 assetId, uint128 price, uint64 computedAt)
        public
    {
        bytes memory _message =
            abi.encodePacked(uint8(MessagesLib.Call.UpdateTranchePrice), poolId, trancheId, assetId, price, computedAt);
        _execute(_message);
    }

    function updateCentrifugeGasPrice(uint128 price, uint64 computedAt) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.UpdateCentrifugeGasPrice), price, computedAt);
        _execute(_message);
    }

    function triggerIncreaseRedeemOrder(
        uint64 poolId,
        bytes16 trancheId,
        address investor,
        uint128 assetId,
        uint128 amount
    ) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.TriggerRedeemRequest), poolId, trancheId, investor.toBytes32(), assetId, amount
        );
        _execute(_message);
    }

    // Trigger an incoming (e.g. Centrifuge Chain -> EVM) transfer of stable coins
    function incomingTransfer(uint128 assetId, bytes32 recipient, uint128 amount) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.TransferAssets), assetId, recipient, amount);
        _execute(_message);
    }

    // Trigger an incoming (e.g. Centrifuge Chain -> EVM) transfer of tranche tokens
    function incomingTransferTrancheTokens(
        uint64 poolId,
        bytes16 trancheId,
        uint64 destinationChainId,
        address destinationAddress,
        uint128 amount
    ) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.TransferTrancheTokens),
            poolId,
            trancheId,
            bytes9(BytesLib.slice(abi.encodePacked(uint8(Domain.EVM), destinationChainId), 0, 9)),
            destinationAddress.toBytes32(),
            amount
        );
        _execute(_message);
    }

    function incomingScheduleUpgrade(address target) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.ScheduleUpgrade), target);
        _execute(_message);
    }

    function incomingCancelUpgrade(address target) public {
        bytes memory _message = abi.encodePacked(uint8(MessagesLib.Call.CancelUpgrade), target);
        _execute(_message);
    }

    function freeze(uint64 poolId, bytes16 trancheId, address user) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.UpdateRestriction),
            poolId,
            trancheId,
            uint8(RestrictionUpdate.Freeze),
            user.toBytes32()
        );
        _execute(_message);
    }

    function unfreeze(uint64 poolId, bytes16 trancheId, address user) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.UpdateRestriction),
            poolId,
            trancheId,
            uint8(RestrictionUpdate.Unfreeze),
            user.toBytes32()
        );
        _execute(_message);
    }

    function recoverTokens(address target, address token, address to, uint256 amount) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.RecoverTokens), target.toBytes32(), token.toBytes32(), to.toBytes32(), amount
        );
        _execute(_message);
    }

    function isFulfilledCancelDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets,
        uint128 fulfillment
    ) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledCancelDepositRequest),
            poolId,
            trancheId,
            investor,
            assetId,
            assets,
            fulfillment
        );
        _execute(_message);
    }

    function isFulfilledCancelRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 shares
    ) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledCancelRedeemRequest), poolId, trancheId, investor, assetId, shares
        );
        _execute(_message);
    }

    function isFulfilledDepositRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledDepositRequest), poolId, trancheId, investor, assetId, assets, shares
        );
        _execute(_message);
    }

    function isFulfilledRedeemRequest(
        uint64 poolId,
        bytes16 trancheId,
        bytes32 investor,
        uint128 assetId,
        uint128 assets,
        uint128 shares
    ) public {
        bytes memory _message = abi.encodePacked(
            uint8(MessagesLib.Call.FulfilledRedeemRequest), poolId, trancheId, investor, assetId, assets, shares
        );
        _execute(_message);
    }

    function execute(bytes memory message) external {
        _execute(message);
    }

    /// @dev Adds zero padding
    function _toBytes128(string memory source) internal pure returns (bytes memory) {
        bytes memory sourceBytes = bytes(source);
        return bytes.concat(sourceBytes, new bytes(128 - sourceBytes.length));
    }

    function _execute(bytes memory message) internal {
        bytes memory proof = abi.encodePacked(uint8(MessagesLib.Call.MessageProof), keccak256(message));
        for (uint256 i = 0; i < adapters.length; i++) {
            AdapterLike(adapters[i]).execute(i == 0 ? message : proof);
        }
    }

    // Added to be ignored in coverage report
    function test() public {}
}
