// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import "forge-std/Test.sol";

contract CastLibTest is Test {
    function testToAddress(address addr) public pure {
        assertEq(CastLib.toAddress(bytes32(bytes20(addr))), addr);
    }

    function testToAddressInvalid(address addr, bytes12 nonZero) public {
        nonZero = bytes12(uint96(bound(uint96(nonZero), 1, type(uint96).max)));

        bytes32 input = bytes32(bytes.concat(bytes20(addr), nonZero));

        vm.expectRevert(CastLib.PrefixNotZero.selector);
        this.toAddress(input);
    }

    function toAddress(bytes32 input) external pure returns (address) {
        return CastLib.toAddress(input);
    }
}
