// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {UpdateRestrictionMessageLib} from "../../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import "forge-std/Test.sol";

// The following tests check that the function composition of deserializing and serializing equals to the identity:
//       I = deserialize º serialize
// NOTE. To fully ensure a good testing, use different values for each field.
contract TestUpdateRestrictionMessageLibIdentities is Test {
    using UpdateRestrictionMessageLib for *;

    function testUpdateRestrictionMember(bytes32 user, uint64 validUntil) public pure {
        UpdateRestrictionMessageLib.UpdateRestrictionMember memory aa =
            UpdateRestrictionMessageLib.UpdateRestrictionMember({user: user, validUntil: validUntil});
        UpdateRestrictionMessageLib.UpdateRestrictionMember memory bb =
            UpdateRestrictionMessageLib.deserializeUpdateRestrictionMember(aa.serialize());

        assertEq(aa.user, bb.user);
        assertEq(aa.validUntil, bb.validUntil);
    }

    function testUpdateRestrictionFreeze(bytes32 user) public pure {
        UpdateRestrictionMessageLib.UpdateRestrictionFreeze memory aa =
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze({user: user});
        UpdateRestrictionMessageLib.UpdateRestrictionFreeze memory bb =
            UpdateRestrictionMessageLib.deserializeUpdateRestrictionFreeze(aa.serialize());

        assertEq(aa.user, bb.user);
    }

    function testUpdateRestrictionUnfreeze(bytes32 user) public pure {
        UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze memory aa =
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze({user: user});
        UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze memory bb =
            UpdateRestrictionMessageLib.deserializeUpdateRestrictionUnfreeze(aa.serialize());

        assertEq(aa.user, bb.user);
    }
}
