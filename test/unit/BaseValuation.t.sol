// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/types/D18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {TransientValuation} from "src/TransientValuation.sol";
import {BaseValuation} from "src/BaseValuation.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IBaseValuation} from "src/interfaces/IBaseValuation.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";

contract BaseValuationImpl is BaseValuation {
    constructor(IAssetManager assetManager, address deployer) BaseValuation(assetManager, deployer) {}

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {}
}

contract TestFile is Test {
    BaseValuationImpl valuation = new BaseValuationImpl(IAssetManager(address(42)), address(this));

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

    function testErrFileUnrecognizedWhat() public {
        vm.expectRevert(abi.encodeWithSelector(IBaseValuation.FileUnrecognizedWhat.selector));
        valuation.file("unrecongnizedWhat", address(23));
    }
}
