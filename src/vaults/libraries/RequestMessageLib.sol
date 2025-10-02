// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

enum RequestType {
    /// @dev Placeholder for null request type
    Invalid,
    DepositRequest,
    RedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest
}

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
        bytes32 investor;
        uint128 amount;
    }

    function deserializeDepositRequest(bytes memory data) internal pure returns (DepositRequest memory) {
        require(requestType(data) == RequestType.DepositRequest, UnknownRequestType());
        return DepositRequest({investor: data.toBytes32(1), amount: data.toUint128(33)});
    }

    function serialize(DepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.DepositRequest, t.investor, t.amount);
    }

    //---------------------------------------
    //    Request.RedeemRequest (submsg)
    //---------------------------------------

    struct RedeemRequest {
        bytes32 investor;
        uint128 amount;
    }

    function deserializeRedeemRequest(bytes memory data) internal pure returns (RedeemRequest memory) {
        require(requestType(data) == RequestType.RedeemRequest, UnknownRequestType());
        return RedeemRequest({investor: data.toBytes32(1), amount: data.toUint128(33)});
    }

    function serialize(RedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.RedeemRequest, t.investor, t.amount);
    }

    //---------------------------------------
    //    Request.CancelDepositRequest (submsg)
    //---------------------------------------

    struct CancelDepositRequest {
        bytes32 investor;
    }

    function deserializeCancelDepositRequest(bytes memory data) internal pure returns (CancelDepositRequest memory) {
        require(requestType(data) == RequestType.CancelDepositRequest, UnknownRequestType());
        return CancelDepositRequest({investor: data.toBytes32(1)});
    }

    function serialize(CancelDepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.CancelDepositRequest, t.investor);
    }

    //---------------------------------------
    //    Request.CancelRedeemRequest (submsg)
    //---------------------------------------

    struct CancelRedeemRequest {
        bytes32 investor;
    }

    function deserializeCancelRedeemRequest(bytes memory data) internal pure returns (CancelRedeemRequest memory) {
        require(requestType(data) == RequestType.CancelRedeemRequest, UnknownRequestType());
        return CancelRedeemRequest({investor: data.toBytes32(1)});
    }

    function serialize(CancelRedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.CancelRedeemRequest, t.investor);
    }
}
