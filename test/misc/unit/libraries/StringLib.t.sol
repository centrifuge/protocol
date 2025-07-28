// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "../../../../src/misc/libraries/StringLib.sol";

import "forge-std/Test.sol";

contract StringLibTest is Test {
    function testStringIsEmpty() public pure {
        assertTrue(StringLib.isEmpty(""));
        assertFalse(StringLib.isEmpty("nonEmpty"));
    }
}
