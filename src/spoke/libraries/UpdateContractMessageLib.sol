// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

enum UpdateContractType {
    /// @dev Placeholder for null update restriction type
    Invalid,
    Valuation,
    SyncDepositMaxReserve,
    UpdateAddress
}

library UpdateContractMessageLib {
    using UpdateContractMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownMessageType();

    function updateContractType(bytes memory message) internal pure returns (UpdateContractType) {
        return UpdateContractType(message.toUint8(0));
    }

    //---------------------------------------
    //   UpdateContract.Valuation (submsg)
    //---------------------------------------

    struct UpdateContractValuation {
        bytes32 valuation;
    }

    function deserializeUpdateContractValuation(bytes memory data)
        internal
        pure
        returns (UpdateContractValuation memory)
    {
        require(updateContractType(data) == UpdateContractType.Valuation, UnknownMessageType());
        return UpdateContractValuation({valuation: data.toBytes32(1)});
    }

    function serialize(UpdateContractValuation memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.Valuation, t.valuation);
    }

    //---------------------------------------
    //   UpdateContract.SyncDepositMaxReserve (submsg)
    //---------------------------------------

    struct UpdateContractSyncDepositMaxReserve {
        uint128 assetId;
        uint128 maxReserve;
    }

    function deserializeUpdateContractSyncDepositMaxReserve(bytes memory data)
        internal
        pure
        returns (UpdateContractSyncDepositMaxReserve memory)
    {
        require(updateContractType(data) == UpdateContractType.SyncDepositMaxReserve, UnknownMessageType());
        return UpdateContractSyncDepositMaxReserve({assetId: data.toUint128(1), maxReserve: data.toUint128(17)});
    }

    function serialize(UpdateContractSyncDepositMaxReserve memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.SyncDepositMaxReserve, t.assetId, t.maxReserve);
    }

    //---------------------------------------
    //   UpdateContract.UpdateAddress (submsg)
    //---------------------------------------

    struct UpdateContractUpdateAddress {
        bytes32 kind;
        uint128 assetId;
        bytes32 what;
        bool isEnabled;
    }

    function deserializeUpdateContractUpdateAddress(bytes memory data)
        internal
        pure
        returns (UpdateContractUpdateAddress memory)
    {
        require(updateContractType(data) == UpdateContractType.UpdateAddress, UnknownMessageType());

        return UpdateContractUpdateAddress({
            kind: data.toBytes32(1),
            assetId: data.toUint128(33),
            what: data.toBytes32(49),
            isEnabled: data.toBool(81)
        });
    }

    function serialize(UpdateContractUpdateAddress memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateContractType.UpdateAddress, t.kind, t.assetId, t.what, t.isEnabled);
    }
}
