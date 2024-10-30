// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "src/libraries/StringLib.sol";

contract StringLibTest is Test {
    function testStringIsEmpty(string memory nonEmptyString) public pure {
        vm.assume(keccak256(abi.encodePacked(nonEmptyString)) != StringLib.EMPTY_STRING);
        assertTrue(StringLib.isEmpty(""));

        assertFalse(StringLib.isEmpty(nonEmptyString));
    }
}
