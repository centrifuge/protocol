// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/types/D18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {TransientValuation} from "src/TransientValuation.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";

contract C18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract C6 {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract TestPortfolio is Test {
    address c18 = address(new C18());
    address c6 = address(new C6());
    TransientValuation valuation = new TransientValuation();

    function testSameDecimals() public {
        valuation.setPrice(d18(2, 1)); //2.0

        assertEq(valuation.getQuote(100 * 1e6, c6, c6), 200 * 1e6);
    }

    function testHighPriceFromMoreDecimalsToLess() public {
        valuation.setPrice(d18(3, 1)); //3.0

        assertEq(valuation.getQuote(100 * 1e18, c18, c6), 300 * 1e6);
    }

    function testLowPriceFromMoreDecimalsToLess() public {
        valuation.setPrice(d18(1, 3)); // 0.33...

        assertEq(valuation.getQuote(100 * 1e18, c18, c6), 33_333_333);
    }

    function testHighPriceFromLessDecimalsToMore() public {
        valuation.setPrice(d18(3, 1)); //3.0

        assertEq(valuation.getQuote(100 * 1e6, c6, c18), 300 * 1e18);
    }

    function testLowPriceFromLessDecimalsToMore() public {
        valuation.setPrice(d18(1, 3)); //0.33...

        // Note: last 2 zeros from the Eq is due lost of precision given the price only contains 18 decimals.
        assertEq(valuation.getQuote(100 * 1e6, c6, c18), 33_333_333_333_333_333_300);
    }
}
