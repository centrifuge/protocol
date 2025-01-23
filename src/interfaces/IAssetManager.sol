// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// TODO
interface IAssetManager {
    function decimals(uint256 tokenId) external view returns (uint8);
}
