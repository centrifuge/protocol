// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RequestId} from "../../src/core/types/RequestId.sol";

import {VaultRequestIdLib} from "../../src/vaults/libraries/VaultRequestIdLib.sol";

import "forge-std/Test.sol";

/// @dev The id layout is what makes parallel vaults on one pool position collision-free and makes
///      callbacks self-routing, so the packing is specified here rather than inferred from callers.
contract VaultRequestIdLibTest is Test {
    using VaultRequestIdLib for RequestId;

    function testRoundTrip(address vault, uint96 localId) public pure {
        RequestId id = VaultRequestIdLib.from(vault, localId);

        assertEq(id.vaultOf(), vault, "vault survives the round trip");
        assertEq(id.localIdOf(), localId, "local id survives the round trip");
    }

    function testLayout(address vault, uint96 localId) public pure {
        RequestId id = VaultRequestIdLib.from(vault, localId);

        assertEq(RequestId.unwrap(id) >> 96, uint256(uint160(vault)), "vault occupies the high 160 bits");
        assertEq(uint96(RequestId.unwrap(id)), localId, "local id occupies the low 96 bits");
    }

    /// @dev The collision-freedom claim: two vaults may hand out the same local id, and the ids stay
    ///      distinct. Without this every parallel vault on a position would need an id registry.
    function testDistinctVaultsNeverCollide(address vaultA, address vaultB, uint96 localId) public pure {
        vm.assume(vaultA != vaultB);

        assertNotEq(
            RequestId.unwrap(VaultRequestIdLib.from(vaultA, localId)),
            RequestId.unwrap(VaultRequestIdLib.from(vaultB, localId)),
            "same local id, different vaults"
        );
    }

    function testDistinctLocalIdsNeverCollide(address vault, uint96 a, uint96 b) public pure {
        vm.assume(a != b);

        assertNotEq(
            RequestId.unwrap(VaultRequestIdLib.from(vault, a)),
            RequestId.unwrap(VaultRequestIdLib.from(vault, b)),
            "same vault, different local ids"
        );
    }

    /// @dev A request id whose high bits name another vault decodes to that vault, which is what the
    ///      vault's own `pending*Request` views and the router's dispatch rely on to reject it.
    function testForeignIdDecodesToItsOwner(address foreign, uint96 localId) public view {
        vm.assume(foreign != address(this));

        assertEq(VaultRequestIdLib.from(foreign, localId).vaultOf(), foreign);
        assertNotEq(VaultRequestIdLib.from(foreign, localId).vaultOf(), address(this));
    }
}
