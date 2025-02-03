// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {addrToAssedId} from "src/types/AssetId.sol";
import {MathLib} from "src/libraries/MathLib.sol";

contract AssetIdUtilitiesTest is Test {
    function testSuccessfulConversion() public pure {
        address assetId = address(uint160(type(uint128).max));
        assertEq(type(uint128).max, addrToAssedId(assetId).raw());
    }

    function testRevertOnUnsupportedConversion() public {
        address assetId = address(uint160(type(uint128).max) + 1);
        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        addrToAssedId(assetId);
    }
}
