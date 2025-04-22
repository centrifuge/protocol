// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/misc/types/D18.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IBaseValuation} from "src/misc/interfaces/IBaseValuation.sol";
import {IERC6909Decimals} from "src/misc/interfaces/IERC6909.sol";
import {BaseValuation} from "src/misc/BaseValuation.sol";

contract BaseValuationImpl is BaseValuation {
    constructor(IERC6909Decimals assetRegistry, address deployer) BaseValuation(assetRegistry, deployer) {}

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {}
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
