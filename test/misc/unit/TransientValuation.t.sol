// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {D18, d18} from "src/misc/types/D18.sol";

import {TransientValuation} from "test/misc/mocks/TransientValuation.sol";
import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";

address constant C6 = address(6);
address constant C18 = address(18);

contract TestTransientValuation is Test {
    TransientValuation valuation = new TransientValuation(new MockERC6909());

    function testSameDecimals() public {
        valuation.setPrice(C6, C6, d18(2, 1)); //2.0

        assertEq(valuation.getQuote(100 * 1e6, C6, C6), 200 * 1e6);
    }

    function testHighPriceFromMoreDecimalsToLess() public {
        valuation.setPrice(C18, C6, d18(3, 1)); //3.0

        assertEq(valuation.getQuote(100 * 1e18, C18, C6), 300 * 1e6);
    }

    function testLowPriceFromMoreDecimalsToLess() public {
        valuation.setPrice(C18, C6, d18(1, 3)); // 0.33...

        assertEq(valuation.getQuote(100 * 1e18, C18, C6), 33_333_333);
    }

    function testHighPriceFromLessDecimalsToMore() public {
        valuation.setPrice(C6, C18, d18(3, 1)); //3.0

        assertEq(valuation.getQuote(100 * 1e6, C6, C18), 300 * 1e18);
    }

    function testLowPriceFromLessDecimalsToMore() public {
        valuation.setPrice(C6, C18, d18(1, 3)); //0.33...

        // Note: last 2 zeros from the Eq is due lost of precision given the price only contains 18 decimals.
        assertEq(valuation.getQuote(100 * 1e6, C6, C18), 33_333_333_333_333_333_300);
    }

    function testMultiplePricesAtTheSameTime() public {
        valuation.setPrice(C6, C6, d18(2, 1)); //2.0
        valuation.setPrice(C6, C18, d18(3, 1)); //3.0
        valuation.setPrice(C18, C18, d18(4, 1)); //4.0

        assertEq(valuation.getQuote(1e6, C6, C6), 2 * 1e6);
        assertEq(valuation.getQuote(1e6, C6, C18), 3 * 1e18);
        assertEq(valuation.getQuote(1e18, C18, C18), 4 * 1e18);
    }

    function testErrPriceNotSet() public {
        vm.expectRevert(abi.encodeWithSelector(TransientValuation.PriceNotSet.selector, C6, C18));
        valuation.getQuote(1 * 1e6, C6, C18);
    }
}
