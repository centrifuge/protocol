// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC6909} from "src/misc/ERC6909.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";

contract MockERC6909 is IERC6909MetadataExt {
    mapping(address owner => mapping(uint256 tokenId => uint256)) public balanceOf;
    mapping(address owner => mapping(address spender => mapping(uint256 tokenId => uint256))) public allowance;

    error InsufficientBalance();

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

    function mint(address owner, uint256 tokenId, uint256 amount) external {
        balanceOf[owner][tokenId] += amount;
    }

    function transfer(address receiver, uint256 tokenId, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender][tokenId] >= amount, InsufficientBalance());
        balanceOf[receiver][tokenId] += amount;
        balanceOf[msg.sender][tokenId] -= amount;
        return true;
    }
}
