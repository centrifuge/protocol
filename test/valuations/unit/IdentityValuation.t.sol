// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {MockERC6909} from "../../misc/mocks/MockERC6909.sol";

import {AssetId} from "../../../src/common/types/AssetId.sol";

import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import "forge-std/Test.sol";

AssetId constant C6 = AssetId.wrap(6);
AssetId constant C18 = AssetId.wrap(18);

contract TestIdentityValuation is Test {
    IdentityValuation valuation = new IdentityValuation(new MockERC6909(), address(0));

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
