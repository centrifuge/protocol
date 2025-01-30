// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

contract MockAssetManager {
    function decimals(address tokenId) external pure returns (uint8) {
        return uint8(uint256(uint160(tokenId)));
    }
}
