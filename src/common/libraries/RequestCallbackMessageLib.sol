// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

enum RequestCallbackType {
    /// @dev Placeholder for null request callback type
    Invalid,
    ApprovedDeposits,
    IssuedShares,
    RevokedShares,
    FulfilledDepositRequest,
    FulfilledRedeemRequest
}

library RequestCallbackMessageLib {
    using RequestCallbackMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownRequestCallbackType();

    function requestCallbackType(bytes memory message) internal pure returns (RequestCallbackType) {
        return RequestCallbackType(message.toUint8(0));
    }

    //---------------------------------------
    //    RequestCallback.ApprovedDeposits (submsg)
    //---------------------------------------

    struct ApprovedDeposits {
        uint128 assetAmount;
        uint128 pricePoolPerAsset;
    }

    function deserializeApprovedDeposits(bytes memory data) internal pure returns (ApprovedDeposits memory) {
        require(requestCallbackType(data) == RequestCallbackType.ApprovedDeposits, UnknownRequestCallbackType());

        return ApprovedDeposits({assetAmount: data.toUint128(1), pricePoolPerAsset: data.toUint128(17)});
    }

    function serialize(ApprovedDeposits memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestCallbackType.ApprovedDeposits, t.assetAmount, t.pricePoolPerAsset);
    }

    //---------------------------------------
    //    RequestCallback.IssuedShares (submsg)
    //---------------------------------------

    struct IssuedShares {
        uint128 shareAmount;
        uint128 pricePoolPerShare;
    }

    function deserializeIssuedShares(bytes memory data) internal pure returns (IssuedShares memory) {
        require(requestCallbackType(data) == RequestCallbackType.IssuedShares, UnknownRequestCallbackType());

        return IssuedShares({shareAmount: data.toUint128(1), pricePoolPerShare: data.toUint128(17)});
    }

    function serialize(IssuedShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestCallbackType.IssuedShares, t.shareAmount, t.pricePoolPerShare);
    }

    //---------------------------------------
    //    RequestCallback.RevokedShares (submsg)
    //---------------------------------------

    struct RevokedShares {
        uint128 assetAmount;
        uint128 shareAmount;
        uint128 pricePoolPerShare;
    }

    function deserializeRevokedShares(bytes memory data) internal pure returns (RevokedShares memory) {
        require(requestCallbackType(data) == RequestCallbackType.RevokedShares, UnknownRequestCallbackType());

        return RevokedShares({
            assetAmount: data.toUint128(1),
            shareAmount: data.toUint128(17),
            pricePoolPerShare: data.toUint128(33)
        });
    }

    function serialize(RevokedShares memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestCallbackType.RevokedShares, t.assetAmount, t.shareAmount, t.pricePoolPerShare);
    }

    //---------------------------------------
    //    RequestCallback.FulfilledDepositRequest (submsg)
    //---------------------------------------

    struct FulfilledDepositRequest {
        bytes32 investor;
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
            investor: data.toBytes32(1),
            fulfilledAssetAmount: data.toUint128(33),
            fulfilledShareAmount: data.toUint128(49),
            cancelledAssetAmount: data.toUint128(65)
        });
    }

    function serialize(FulfilledDepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.FulfilledDepositRequest,
            t.investor,
            t.fulfilledAssetAmount,
            t.fulfilledShareAmount,
            t.cancelledAssetAmount
        );
    }

    //---------------------------------------
    //    RequestCallback.FulfilledRedeemRequest (submsg)
    //---------------------------------------

    struct FulfilledRedeemRequest {
        bytes32 investor;
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
            investor: data.toBytes32(1),
            fulfilledAssetAmount: data.toUint128(33),
            fulfilledShareAmount: data.toUint128(49),
            cancelledShareAmount: data.toUint128(65)
        });
    }

    function serialize(FulfilledRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.FulfilledRedeemRequest,
            t.investor,
            t.fulfilledAssetAmount,
            t.fulfilledShareAmount,
            t.cancelledShareAmount
        );
    }
}
