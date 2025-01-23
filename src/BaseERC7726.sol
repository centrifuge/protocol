// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {D18} from "src/types/D18.sol";

import {Conversion} from "src/libraries/Conversion.sol";

import {IERC7726} from "src/interfaces/IERC7726.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";

interface IAssetManager {
    function decimals(uint256 tokenId) external view returns (uint8);
}

abstract contract BaseERC7726 is IERC7726 {
    uint160 private constant ASSET_MANAGER_TOKEN = type(uint64).max;

    /// @notice Temporal price set and used to obtain the quote.
    IAssetManager public assetManager;

    function _getDecimals(address asset) internal view returns (uint8) {
        if (uint160(asset) <= ASSET_MANAGER_TOKEN) {
            // The address is a TokenId registered in the AssetManager
            return assetManager.decimals(uint160(asset));
        } else {
            return IERC20Metadata(asset).decimals();
        }
    }
}
