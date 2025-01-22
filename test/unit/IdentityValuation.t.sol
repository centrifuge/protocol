// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/types/D18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {IdentityValuation} from "src/IdentityValuation.sol";
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

contract TestIdentityValuation is Test {
    address c18 = address(new C18());
    address c6 = address(new C6());
    IdentityValuation valuation = new IdentityValuation();

    function testSameDecimals() public view {
        assertEq(valuation.getQuote(100 * 1e6, c6, c6), 100 * 1e6);
    }

    function testFromMoreDecimalsToLess() public view {
        assertEq(valuation.getQuote(100 * 1e18, c18, c6), 100 * 1e6);
    }

    function testFromLessDecimalsToMore() public view {
        assertEq(valuation.getQuote(100 * 1e6, c6, c18), 100 * 1e18);
    }
}
