// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

enum UpdateRestrictionType {
    /// @dev Placeholder for null update restriction type
    Invalid,
    Member,
    Freeze,
    Unfreeze
}

library UpdateRestrictionMessageLib {
    using UpdateRestrictionMessageLib for bytes;
    using BytesLib for bytes;
    using CastLib for *;

    error UnknownMessageType();

    function updateRestrictionType(bytes memory message) internal pure returns (UpdateRestrictionType) {
        return UpdateRestrictionType(message.toUint8(0));
    }

    //---------------------------------------
    //    UpdateRestrictionMember (submsg)
    //---------------------------------------

    struct UpdateRestrictionMember {
        bytes32 user;
        uint64 validUntil;
    }

    function deserializeUpdateRestrictionMember(bytes memory data)
        internal
        pure
        returns (UpdateRestrictionMember memory)
    {
        require(updateRestrictionType(data) == UpdateRestrictionType.Member, UnknownMessageType());
        return UpdateRestrictionMember({user: data.toBytes32(1), validUntil: data.toUint64(33)});
    }

    function serialize(UpdateRestrictionMember memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateRestrictionType.Member, t.user, t.validUntil);
    }

    //---------------------------------------
    //    UpdateRestrictionFreeze (submsg)
    //---------------------------------------

    struct UpdateRestrictionFreeze {
        bytes32 user;
    }

    function deserializeUpdateRestrictionFreeze(bytes memory data)
        internal
        pure
        returns (UpdateRestrictionFreeze memory)
    {
        require(updateRestrictionType(data) == UpdateRestrictionType.Freeze, UnknownMessageType());
        return UpdateRestrictionFreeze({user: data.toBytes32(1)});
    }

    function serialize(UpdateRestrictionFreeze memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateRestrictionType.Freeze, t.user);
    }

    //---------------------------------------
    //    UpdateRestrictionUnfreeze (submsg)
    //---------------------------------------

    struct UpdateRestrictionUnfreeze {
        bytes32 user;
    }

    function deserializeUpdateRestrictionUnfreeze(bytes memory data)
        internal
        pure
        returns (UpdateRestrictionUnfreeze memory)
    {
        require(updateRestrictionType(data) == UpdateRestrictionType.Unfreeze, UnknownMessageType());
        return UpdateRestrictionUnfreeze({user: data.toBytes32(1)});
    }

    function serialize(UpdateRestrictionUnfreeze memory t) internal pure returns (bytes memory) {
        return abi.encodePacked(UpdateRestrictionType.Unfreeze, t.user);
    }
}
