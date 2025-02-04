// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract MockAssetManager {
    function decimals(uint256 tokenId) external pure returns (uint8) {
        return uint8(tokenId);
    }
}
