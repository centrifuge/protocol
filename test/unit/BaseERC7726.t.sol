// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {D18, d18} from "src/types/D18.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {TransientValuation} from "src/TransientValuation.sol";
import {BaseERC7726} from "src/BaseERC7726.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IBaseERC7726} from "src/interfaces/IBaseERC7726.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";

contract BaseERC7726Impl is BaseERC7726 {
    constructor(IAssetManager assetManager, address deployer) BaseERC7726(assetManager, deployer) {}

    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {}
}

contract TestFile is Test {
    BaseERC7726Impl valuation = new BaseERC7726Impl(IAssetManager(address(42)), address(this));

    function testSuccess() public {
        vm.expectEmit();
        emit IBaseERC7726.File("assetManager", address(23));
        valuation.file("assetManager", address(23));

        assertEq(address(valuation.assetManager()), address(23));
    }

    function testErrNotAuthorized() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        valuation.file("assetManager", address(23));
    }

    function testErrFileUnrecognizedWhat() public {
        vm.expectRevert(abi.encodeWithSelector(IBaseERC7726.FileUnrecognizedWhat.selector));
        valuation.file("unrecongnizedWhat", address(23));
    }
}
