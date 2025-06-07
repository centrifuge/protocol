// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

enum RequestCallbackType {
    /// @dev Placeholder for null request callback type
    Invalid,
    ApprovedDeposits,
    IssuedShares,
    RevokedShares,
    FulfilledDepositRequest,
    FulfilledRedeemRequest
}

// TODO: remove poolId and scId from all sub messages
// TODO: add assetId to higher level RequestCallback message

library RequestCallbackMessageLib {
    using RequestCallbackMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownRequestCallbackType();

    function requestCallbackType(bytes memory message) internal pure returns (RequestCallbackType) {
        return RequestCallbackType(message.toUint8(0));
    }

    //---------------------------------------
    //    Request.ApprovedDeposits (submsg)
    //---------------------------------------

    struct ApprovedDeposits {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
        uint128 assetAmount;
        uint128 pricePoolPerAsset;
    }

    function deserializeApprovedDeposits(bytes memory data) internal pure returns (ApprovedDeposits memory) {
        require(requestCallbackType(data) == RequestCallbackType.ApprovedDeposits, UnknownRequestCallbackType());

        return ApprovedDeposits({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            assetId: data.toUint128(25),
            assetAmount: data.toUint128(41),
            pricePoolPerAsset: data.toUint128(57)
        });
    }

    function serialize(ApprovedDeposits memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.ApprovedDeposits, t.poolId, t.scId, t.assetId, t.assetAmount, t.pricePoolPerAsset
        );
    }

    //---------------------------------------
    //    Request.IssuedShares (submsg)
    //---------------------------------------

    struct IssuedShares {
        uint64 poolId;
        bytes16 scId;
        uint128 shareAmount;
        uint128 pricePoolPerShare;
    }

    function deserializeIssuedShares(bytes memory data) internal pure returns (IssuedShares memory) {
        require(requestCallbackType(data) == RequestCallbackType.IssuedShares, UnknownRequestCallbackType());

        return IssuedShares({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            shareAmount: data.toUint128(25),
            pricePoolPerShare: data.toUint128(41)
        });
    }

    function serialize(IssuedShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestCallbackType.IssuedShares, t.poolId, t.scId, t.shareAmount, t.pricePoolPerShare);
    }

    //---------------------------------------
    //    Request.RevokedShares (submsg)
    //---------------------------------------

    struct RevokedShares {
        uint64 poolId;
        bytes16 scId;
        uint128 assetId;
        uint128 shareAmount;
        uint128 pricePoolPerShare;
        uint128 assetAmount;
    }

    function deserializeRevokedShares(bytes memory data) internal pure returns (RevokedShares memory) {
        require(requestCallbackType(data) == RequestCallbackType.RevokedShares, UnknownRequestCallbackType());

        return RevokedShares({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            assetId: data.toUint128(25),
            assetAmount: data.toUint128(41),
            shareAmount: data.toUint128(57),
            pricePoolPerShare: data.toUint128(73)
        });
    }

    function serialize(RevokedShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.RevokedShares,
            t.poolId,
            t.scId,
            t.assetId,
            t.assetAmount,
            t.shareAmount,
            t.pricePoolPerShare
        );
    }

    //---------------------------------------
    //    Request.FulfilledDepositRequest (submsg)
    //---------------------------------------

    struct FulfilledDepositRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 fulfilledAssetAmount;
        uint128 fulfilledShareAmount;
        uint128 cancelledAssetAmount;
    }

    function deserializeFulfilledDepositRequest(bytes memory data)
        internal
        pure
        returns (FulfilledDepositRequest memory)
    {
        require(requestCallbackType(data) == RequestCallbackType.FulfilledDepositRequest, UnknownRequestCallbackType());
        return FulfilledDepositRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            fulfilledAssetAmount: data.toUint128(73),
            fulfilledShareAmount: data.toUint128(89),
            cancelledAssetAmount: data.toUint128(105)
        });
    }

    function serialize(FulfilledDepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.FulfilledDepositRequest,
            t.poolId,
            t.scId,
            t.investor,
            t.assetId,
            t.fulfilledAssetAmount,
            t.fulfilledShareAmount,
            t.cancelledAssetAmount
        );
    }

    //---------------------------------------
    //    Request.FulfilledRedeemRequest (submsg)
    //---------------------------------------

    struct FulfilledRedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 fulfilledAssetAmount;
        uint128 fulfilledShareAmount;
        uint128 cancelledShareAmount;
    }

    function deserializeFulfilledRedeemRequest(bytes memory data)
        internal
        pure
        returns (FulfilledRedeemRequest memory)
    {
        require(requestCallbackType(data) == RequestCallbackType.FulfilledRedeemRequest, UnknownRequestCallbackType());
        return FulfilledRedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            fulfilledAssetAmount: data.toUint128(73),
            fulfilledShareAmount: data.toUint128(89),
            cancelledShareAmount: data.toUint128(105)
        });
    }

    function serialize(FulfilledRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.FulfilledRedeemRequest,
            t.poolId,
            t.scId,
            t.investor,
            t.assetId,
            t.fulfilledAssetAmount,
            t.fulfilledShareAmount,
            t.cancelledShareAmount
        );
    }
}
