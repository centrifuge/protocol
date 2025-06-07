// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

enum RequestType {
    /// @dev Placeholder for null request type
    Invalid,
    DepositRequest,
    RedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest
}

// TODO: remove poolId and scId from all sub messages
// TODO: add assetId to higher level RequestCallback message

library RequestMessageLib {
    using RequestMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownRequestType();

    function requestType(bytes memory message) internal pure returns (RequestType) {
        return RequestType(message.toUint8(0));
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
}
