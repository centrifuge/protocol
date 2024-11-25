// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "src/libraries/StringLib.sol";

contract StringLibTest is Test {
    function testStringIsEmpty(string memory nonEmptyString) public pure {
        vm.assume(bytes(nonEmptyString).length != 0);
        assertTrue(StringLib.isEmpty(""));

        assertFalse(StringLib.isEmpty(nonEmptyString));
    }
}
