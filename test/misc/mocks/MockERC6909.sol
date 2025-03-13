// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC6909} from "src/misc/ERC6909.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";

contract MockERC6909 is IERC6909MetadataExt {
    mapping(address owner => mapping(address spender => mapping(uint256 tokenId => uint256))) public allowance;

    function decimals(uint256 tokenId) external pure returns (uint8) {
        return uint8(tokenId);
    }

    function name(uint256 /*tokenId*/ ) external pure returns (string memory) {
        return "mocked name";
    }

    function symbol(uint256 /*tokenId*/ ) external pure returns (string memory) {
        return "mocked symbol";
    }

    function approve(address spender, uint256 tokenId, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][tokenId] = amount;
        return true;
    }
}
