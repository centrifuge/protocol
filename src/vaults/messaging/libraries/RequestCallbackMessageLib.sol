// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "../../../misc/libraries/BytesLib.sol";

import {RequestId} from "../../../core/types/RequestId.sol";

enum RequestCallbackType {
    /// @dev Placeholder for null request callback type
    Invalid,
    CancelledDeposit,
    CancelledRedeem,
    SettledDeposit,
    SettledRedeem
}

library RequestCallbackMessageLib {
    using BytesLib for bytes;

    error UnknownRequestCallbackType();

    function requestCallbackType(bytes memory message) internal pure returns (RequestCallbackType) {
        return RequestCallbackType(message.toUint8(0));
    }

    /// @notice Reads the request id (bytes at offset 1) without deserializing the whole message.
    function requestId(bytes memory message) internal pure returns (RequestId) {
        return RequestId.wrap(message.toUint256(1));
    }

    //---------------------------------------
    //    RequestCallback.SettledDeposit (submsg)
    //---------------------------------------

    /// @dev Approves the assets, issues the shares and fulfills the bucket in one message.
    struct SettledDeposit {
        RequestId requestId;
        uint128 fulfilledAssetAmount;
        uint128 fulfilledShareAmount;
    }

    function deserializeSettledDeposit(bytes memory data) internal pure returns (SettledDeposit memory) {
        require(requestCallbackType(data) == RequestCallbackType.SettledDeposit, UnknownRequestCallbackType());
        return SettledDeposit({
            requestId: RequestId.wrap(data.toUint256(1)),
            fulfilledAssetAmount: data.toUint128(33),
            fulfilledShareAmount: data.toUint128(49)
        });
    }

    function serialize(SettledDeposit memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.SettledDeposit, t.requestId.raw(), t.fulfilledAssetAmount, t.fulfilledShareAmount
        );
    }

    //---------------------------------------
    //    RequestCallback.SettledRedeem (submsg)
    //---------------------------------------

    /// @dev Revokes the shares and fulfills the bucket in one message; see {SettledDeposit}.
    struct SettledRedeem {
        RequestId requestId;
        uint128 fulfilledAssetAmount;
        uint128 fulfilledShareAmount;
    }

    function deserializeSettledRedeem(bytes memory data) internal pure returns (SettledRedeem memory) {
        require(requestCallbackType(data) == RequestCallbackType.SettledRedeem, UnknownRequestCallbackType());
        return SettledRedeem({
            requestId: RequestId.wrap(data.toUint256(1)),
            fulfilledAssetAmount: data.toUint128(33),
            fulfilledShareAmount: data.toUint128(49)
        });
    }

    function serialize(SettledRedeem memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(
            RequestCallbackType.SettledRedeem, t.requestId.raw(), t.fulfilledAssetAmount, t.fulfilledShareAmount
        );
    }

    //---------------------------------------
    //    RequestCallback.CancelledDeposit (submsg)
    //---------------------------------------

    /// @dev See {IVaultDepositCallbacks.cancelDeposit}.
    struct CancelledDeposit {
        RequestId requestId;
        uint128 grossAssetAmount;
        uint128 netAssetAmount;
    }

    function deserializeCancelledDeposit(bytes memory data) internal pure returns (CancelledDeposit memory) {
        require(requestCallbackType(data) == RequestCallbackType.CancelledDeposit, UnknownRequestCallbackType());
        return CancelledDeposit({
            requestId: RequestId.wrap(data.toUint256(1)),
            grossAssetAmount: data.toUint128(33),
            netAssetAmount: data.toUint128(49)
        });
    }

    function serialize(CancelledDeposit memory t) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                RequestCallbackType.CancelledDeposit, t.requestId.raw(), t.grossAssetAmount, t.netAssetAmount
            );
    }

    //---------------------------------------
    //    RequestCallback.CancelledRedeem (submsg)
    //---------------------------------------

    /// @dev Share-denominated twin of {CancelledDeposit}.
    struct CancelledRedeem {
        RequestId requestId;
        uint128 grossShareAmount;
        uint128 netShareAmount;
    }

    function deserializeCancelledRedeem(bytes memory data) internal pure returns (CancelledRedeem memory) {
        require(requestCallbackType(data) == RequestCallbackType.CancelledRedeem, UnknownRequestCallbackType());
        return CancelledRedeem({
            requestId: RequestId.wrap(data.toUint256(1)),
            grossShareAmount: data.toUint128(33),
            netShareAmount: data.toUint128(49)
        });
    }

    function serialize(CancelledRedeem memory t) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                RequestCallbackType.CancelledRedeem, t.requestId.raw(), t.grossShareAmount, t.netShareAmount
            );
    }
}
