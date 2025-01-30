// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {AssetId} from "src/types/AssetId.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {AssetIdLib} from "src/libraries/AssetIdLib.sol";

contract AssetIdLibTest is Test {
    using AssetIdLib for address;

    function testSuccessfulConversion() public pure {
        address assetId = address(uint160(type(uint128).max));
        assertEq(type(uint128).max, assetId.asAssetId().raw());
    }

    function testRevertOnUnsupportedConversion() public {
        address assetId = address(uint160(type(uint128).max) + 1);
        vm.expectRevert(MathLib.Uint128_Overflow.selector);
        assetId.asAssetId();
    }
}
