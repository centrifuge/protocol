// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";

import "forge-std/Test.sol";

contract AssetIdTest is Test {
    function testAssetId(uint32 counter, uint16 centrifugeId) public pure {
        centrifugeId = uint16(bound(centrifugeId, 1, type(uint16).max));
        AssetId assetId = newAssetId(centrifugeId, counter);

        assertEq(assetId.isNull(), false);
        assertEq(assetId.centrifugeId(), centrifugeId);
        assertEq(uint32(assetId.raw()), counter);
    }

    function testAssetIdIso(uint32 isoCode) public pure {
        isoCode = uint32(bound(isoCode, 1, type(uint32).max));
        AssetId assetId = newAssetId(isoCode);

        assertEq(assetId.isNull(), false);
        assertEq(assetId.centrifugeId(), uint32(0));
        assertEq(uint32(assetId.raw()), isoCode);
    }
}
