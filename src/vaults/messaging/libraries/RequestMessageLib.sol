// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../../misc/libraries/BytesLib.sol";

import {RequestId} from "../../../core/types/RequestId.sol";

enum RequestType {
    /// @dev Placeholder for null request type
    Invalid,
    DepositRequest,
    RedeemRequest
}

library RequestMessageLib {
    using BytesLib for bytes;

    error UnknownRequestType();

    function requestType(bytes memory message) internal pure returns (RequestType) {
        return RequestType(message.toUint8(0));
    }

    /// @dev Either request, which share a layout, as its side, vault-namespaced id and amount.
    function deserializeRequest(bytes memory data)
        internal
        pure
        returns (bool isDeposit, RequestId requestId, uint128 amount)
    {
        if (requestType(data) == RequestType.DepositRequest) {
            DepositRequest memory d = deserializeDepositRequest(data);
            return (true, d.requestId, d.amount);
        }

        RedeemRequest memory r = deserializeRedeemRequest(data);
        return (false, r.requestId, r.amount);
    }

    //---------------------------------------
    //    Request.DepositRequest (submsg)
    //---------------------------------------

    /// @dev `requestId` is the vault-namespaced ERC-7540 id.
    struct DepositRequest {
        RequestId requestId;
        uint128 amount;
    }

    function deserializeDepositRequest(bytes memory data) internal pure returns (DepositRequest memory) {
        require(requestType(data) == RequestType.DepositRequest, UnknownRequestType());
        return DepositRequest({requestId: RequestId.wrap(data.toUint256(1)), amount: data.toUint128(33)});
    }

    function serialize(DepositRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.DepositRequest, t.requestId.raw(), t.amount);
    }

    //---------------------------------------
    //    Request.RedeemRequest (submsg)
    //---------------------------------------

    /// @dev See {DepositRequest.requestId}.
    struct RedeemRequest {
        RequestId requestId;
        uint128 amount;
    }

    function deserializeRedeemRequest(bytes memory data) internal pure returns (RedeemRequest memory) {
        require(requestType(data) == RequestType.RedeemRequest, UnknownRequestType());
        return RedeemRequest({requestId: RequestId.wrap(data.toUint256(1)), amount: data.toUint128(33)});
    }

    function serialize(RedeemRequest memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(RequestType.RedeemRequest, t.requestId.raw(), t.amount);
    }
}
