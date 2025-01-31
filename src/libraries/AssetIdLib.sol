// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {MathLib} from "src/libraries/MathLib.sol";

library AssetIdLib {
    function asAssetId(address asset) internal pure returns (AssetId) {
        return AssetId.wrap(MathLib.toUint128(uint256(uint160(asset))));
    }
}
