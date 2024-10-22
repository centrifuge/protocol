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

    function testConversionToString() public pure {
        uint256 aNumber = 12345;
        assertEq(StringLib.toString(aNumber), "12345");

        aNumber = 0;
        assertEq(StringLib.toString(aNumber), "0");

        aNumber = type(uint256).max;
        assertEq(
            StringLib.toString(aNumber),
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }
}
