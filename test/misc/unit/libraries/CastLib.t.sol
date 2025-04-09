// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

contract CastLibTest is Test {
    function testToAddress(address addr) public pure {
        assertEq(CastLib.toAddress(bytes32(bytes20(addr))), addr);
    }

    function testToAddressInvalid(address addr, bytes12 nonZero) public {
        vm.assume(uint96(nonZero) > 0);

        bytes32 input = bytes32(bytes.concat(bytes20(addr), nonZero));

        vm.expectRevert(bytes("Input should be 20 bytes"));
        this.toAddress(input);
    }

    function toAddress(bytes32 input) external pure returns (address) {
        return CastLib.toAddress(input);
    }
}
