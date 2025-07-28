// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {IERC6909Decimals} from "../../../src/misc/interfaces/IERC6909.sol";

import {AssetId} from "../../../src/common/types/AssetId.sol";
import {BaseValuation} from "../../../src/common/BaseValuation.sol";
import {IBaseValuation} from "../../../src/common/interfaces/IBaseValuation.sol";

import "forge-std/Test.sol";

contract BaseValuationImpl is BaseValuation {
    constructor(IERC6909Decimals assetRegistry, address deployer) BaseValuation(assetRegistry, deployer) {}

    function getQuote(uint128 baseAmount, AssetId base, AssetId quote) external view returns (uint128 quoteAmount) {}
}

contract TestFile is Test {
    BaseValuationImpl valuation = new BaseValuationImpl(IERC6909Decimals(address(42)), address(this));

    function testSuccess() public {
        vm.expectEmit();
        emit IBaseValuation.File("erc6909", address(23));
        valuation.file("erc6909", address(23));

        assertEq(address(valuation.erc6909()), address(23));
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        valuation.file("erc6909", address(23));
    }

    function testErrFileUnrecognizedParam() public {
        vm.expectRevert(abi.encodeWithSelector(IBaseValuation.FileUnrecognizedParam.selector));
        valuation.file("unrecongnizedWhat", address(23));
    }
}
