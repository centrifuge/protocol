// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

contract MockAssetManager {
    function decimals(address tokenId) external pure returns (uint8) {
        return uint8(uint256(uint160(tokenId)));
    }
}
