// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {AssetId, newAssetId} from "src/common/types/AssetId.sol";

contract AssetIdTest is Test {
    function testAssetId(uint32 counter, uint16 centrifugeId) public pure {
        vm.assume(centrifugeId > 0);
        AssetId assetId = newAssetId(centrifugeId, counter);

        assertEq(assetId.isNull(), false);
        assertEq(assetId.centrifugeId(), centrifugeId);
        assertEq(uint32(assetId.raw()), counter);
        assertEq(assetId.addr(), address(uint160((uint128(centrifugeId) << 112) + counter)));
    }

    function testAssetIdIso(uint32 isoCode) public pure {
        vm.assume(isoCode > 0);
        AssetId assetId = newAssetId(isoCode);

        assertEq(assetId.isNull(), false);
        assertEq(assetId.centrifugeId(), uint32(0));
        assertEq(uint32(assetId.raw()), isoCode);
        assertEq(assetId.addr(), address(uint160(isoCode)));
    }
}
