// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {OneToOneValuation} from "src/misc/OneToOneValuation.sol";

import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";

address constant C6 = address(6);
address constant C18 = address(18);

contract TestOneToOneValuation is Test {
    OneToOneValuation valuation = new OneToOneValuation(new MockERC6909(), address(0));

    function testSameDecimals() public view {
        assertEq(valuation.getQuote(100 * 1e6, C6, C6), 100 * 1e6);
    }

    function testFromMoreDecimalsToLess() public view {
        assertEq(valuation.getQuote(100 * 1e18, C18, C6), 100 * 1e6);
    }

    function testFromLessDecimalsToMore() public view {
        assertEq(valuation.getQuote(100 * 1e6, C6, C18), 100 * 1e18);
    }
}
