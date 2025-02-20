// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";

// TODO: update with the latest version of CV.
// By now, only supported messages are added.
enum MessageType {
    Invalid,
    RegisterAsset,
    AddPool,
    AddTranche,
    AllowAsset,
    DisallowAsset,
    TransferAssets,
    DepositRequest,
    RedeemRequest,
    FulfilledDepositRequest,
    FulfilledRedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest,
    FulfilledCancelDepositRequest,
    FulfilledCancelRedeemRequest
}

library MessageLib {
    using BytesLib for bytes;

    function messageType(bytes memory _msg) public pure returns (MessageType) {
        return MessageType(_msg.toUint8(0));
    }
}
