// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC6909MetadataExt, IERC6909Fungible, IERC6909} from "../../../src/misc/interfaces/IERC6909.sol";

contract MockERC6909 is IERC6909MetadataExt, IERC6909Fungible {
    mapping(address owner => mapping(uint256 tokenId => uint256)) public balanceOf;
    mapping(address owner => mapping(address spender => mapping(uint256 tokenId => uint256))) public allowance;
    mapping(address owner => mapping(address spender => bool)) public operator;

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

    function burn(address owner, uint256 tokenId, uint256 amount) external {
        require(balanceOf[owner][tokenId] >= amount, InsufficientBalance(owner, tokenId));
        balanceOf[owner][tokenId] -= amount;
    }

    function transfer(address receiver, uint256 tokenId, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender][tokenId] >= amount, InsufficientBalance(msg.sender, tokenId));
        balanceOf[receiver][tokenId] += amount;
        balanceOf[msg.sender][tokenId] -= amount;
        return true;
    }

    function transferFrom(address sender, address receiver, uint256 tokenId, uint256 amount) external returns (bool) {
        if (msg.sender != sender) {
            if (operator[sender][msg.sender]) {
                require(allowance[sender][msg.sender][tokenId] >= amount, InsufficientAllowance(sender, tokenId));
            }
        }
        return this.authTransferFrom(sender, receiver, tokenId, amount);
    }

    function authTransferFrom(address sender, address receiver, uint256 tokenId, uint256 amount)
        external
        returns (bool)
    {
        require(balanceOf[sender][tokenId] >= amount, InsufficientBalance(sender, tokenId));
        balanceOf[receiver][tokenId] += amount;
        balanceOf[sender][tokenId] -= amount;
        return true;
    }

    function isOperator(address owner, address operator_) external view returns (bool) {
        return operator[owner][operator_];
    }

    function setOperator(address operator_, bool approved) external returns (bool) {
        operator[msg.sender][operator_] = approved;
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual returns (bool) {
        return type(IERC6909MetadataExt).interfaceId == interfaceId || type(IERC6909Fungible).interfaceId == interfaceId
            || type(IERC6909).interfaceId == interfaceId;
    }
}
