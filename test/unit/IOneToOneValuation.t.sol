// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/types/D18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {OneToOneValuation} from "src/OneToOneValuation.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";
import {MockAssetManager} from "test/mock/MockAssetManager.sol";

address constant C6 = address(6);
address constant C18 = address(18);

contract TestOneToOneValuation is Test {
    OneToOneValuation valuation = new OneToOneValuation(IAssetManager(address(new MockAssetManager())), address(0));

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
