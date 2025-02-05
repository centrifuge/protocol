// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/libraries/BytesLib.sol";
import {CastLib} from "src/libraries/CastLib.sol";

// TODO: update with the latest version of CV.
// By now, only supported messages are added.
enum Call {
    Invalid,
    RegisterAsset,
    AddPool,
    AddTranche,
    AllowAsset,
    DisallowAsset,
    LockedTokens,
    UnlockTokens,
    DepositRequest,
    RedeemRequest,
    FulfilledDepositRequest,
    FulfilledRedeemRequest,
    CancelDepositRequest,
    CancelRedeemRequest,
    FulfilledCancelDepositRequest,
    FulfilledCancelRedeemRequest
}

struct RegisterAssetMsg {
    uint64 assetId;
    string name;
    string symbol;
    uint8 decimals;
}

// Others structs containing the message structure
// ...

library DeserializationLib {
    using BytesLib for bytes;
    using CastLib for bytes;
    using CastLib for bytes32;

    function messageType(bytes memory _msg) public pure returns (Call _call) {
        _call = Call(_msg.toUint8(0));
    }

    function deserializeRegisterAsset(bytes calldata message) public pure returns (RegisterAssetMsg memory) {
        require(messageType(message) == Call.RegisterAsset, "Deserialization error");
        return RegisterAssetMsg(
            message.toUint64(1),
            message.slice(9, 128).bytes128ToString(),
            message.toBytes32(137).toString(),
            message.toUint8(169)
        );
    }

    // Others deserializing methods
    // ...
}

function serialize(RegisterAssetMsg calldata data) pure returns (bytes memory) {
    return abi.encodePacked(uint8(Call.RegisterAsset), data.assetId, data.name, data.symbol, data.decimals);
}

// Others serialize methods
// ...

using {serialize} for RegisterAssetMsg global;
