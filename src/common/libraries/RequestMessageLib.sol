// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

enum RequestType {
    /// @dev Placeholder for null request type
    Invalid,
    ApprovedDeposits,
    IssuedShares,
    RevokedShares,
    DepositRequest,
    RedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest,
    FulfilledDepositRequest,
    FulfilledRedeemRequest
}

// TODO: remove poolId and scId from all sub messages

library RequestMessageLib {
    using RequestMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownRequestType();

    function requestType(bytes memory message) internal pure returns (RequestType) {
        return RequestType(message.toUint8(0));
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
        require(requestType(data) == RequestType.ApprovedDeposits, UnknownRequestType());

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
            RequestType.ApprovedDeposits, t.poolId, t.scId, t.assetId, t.assetAmount, t.pricePoolPerAsset
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
        require(requestType(data) == RequestType.IssuedShares, UnknownRequestType());

        return IssuedShares({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            shareAmount: data.toUint128(25),
            pricePoolPerShare: data.toUint128(41)
        });
    }

    function serialize(IssuedShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.IssuedShares, t.poolId, t.scId, t.shareAmount, t.pricePoolPerShare);
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
        require(requestType(data) == RequestType.RevokedShares, UnknownRequestType());

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
            RequestType.RevokedShares, t.poolId, t.scId, t.assetId, t.assetAmount, t.shareAmount, t.pricePoolPerShare
        );
    }

    //---------------------------------------
    //    Request.DepositRequest (submsg)
    //---------------------------------------

    struct DepositRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 amount;
    }

    function deserializeDepositRequest(bytes memory data) internal pure returns (DepositRequest memory) {
        require(requestType(data) == RequestType.DepositRequest, UnknownRequestType());
        return DepositRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            amount: data.toUint128(73)
        });
    }

    function serialize(DepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.DepositRequest, t.poolId, t.scId, t.investor, t.assetId, t.amount);
    }

    //---------------------------------------
    //    Request.RedeemRequest (submsg)
    //---------------------------------------

    struct RedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
        uint128 amount;
    }

    function deserializeRedeemRequest(bytes memory data) internal pure returns (RedeemRequest memory) {
        require(requestType(data) == RequestType.RedeemRequest, UnknownRequestType());
        return RedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57),
            amount: data.toUint128(73)
        });
    }

    function serialize(RedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.RedeemRequest, t.poolId, t.scId, t.investor, t.assetId, t.amount);
    }

    //---------------------------------------
    //    Request.CancelDepositRequest (submsg)
    //---------------------------------------

    struct CancelDepositRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
    }

    function deserializeCancelDepositRequest(bytes memory data) internal pure returns (CancelDepositRequest memory) {
        require(requestType(data) == RequestType.CancelDepositRequest, UnknownRequestType());
        return CancelDepositRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57)
        });
    }

    function serialize(CancelDepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.CancelDepositRequest, t.poolId, t.scId, t.investor, t.assetId);
    }

    //---------------------------------------
    //    Request.CancelRedeemRequest (submsg)
    //---------------------------------------

    struct CancelRedeemRequest {
        uint64 poolId;
        bytes16 scId;
        bytes32 investor;
        uint128 assetId;
    }

    function deserializeCancelRedeemRequest(bytes memory data) internal pure returns (CancelRedeemRequest memory) {
        require(requestType(data) == RequestType.CancelRedeemRequest, UnknownRequestType());
        return CancelRedeemRequest({
            poolId: data.toUint64(1),
            scId: data.toBytes16(9),
            investor: data.toBytes32(25),
            assetId: data.toUint128(57)
        });
    }

    function serialize(CancelRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.CancelRedeemRequest, t.poolId, t.scId, t.investor, t.assetId);
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
        require(requestType(data) == RequestType.FulfilledDepositRequest, UnknownRequestType());
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
            RequestType.FulfilledDepositRequest,
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
        require(requestType(data) == RequestType.FulfilledRedeemRequest, UnknownRequestType());
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
            RequestType.FulfilledRedeemRequest,
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
