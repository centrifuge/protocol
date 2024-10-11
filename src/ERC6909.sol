// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC6909} from "src/interfaces/IERC6909.sol";
import {IERC165} from "src/interfaces/IERC165.sol";

contract ERC6909 is IERC6909, IERC165 {
    mapping(address owner => mapping(uint256 id => uint256 amount)) public balanceOf;
    mapping(address owner => mapping(address operator => bool isOperator)) public isOperator;
    mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount))) public allowance;

    /// @inheritdoc IERC6909
    function transfer(address receiver, uint256 id, uint256 amount) external returns (bool) {
        return _transfer(msg.sender, receiver, id, amount);
    }

    /// @inheritdoc IERC6909
    function transferFrom(address sender, address receiver, uint256 id, uint256 amount) external returns (bool) {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][id];
            if (allowed != type(uint256).max) allowance[sender][msg.sender][id] = allowed - amount;
        }

        return _transfer(sender, receiver, id, amount);
    }

    /// @inheritdoc IERC6909
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][id] = amount;

        emit Approval(msg.sender, spender, id, amount);

        return true;
    }

    /// @inheritdoc IERC6909
    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;

        emit OperatorSet(msg.sender, operator, approved);

        return true;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return type(IERC6909).interfaceId == interfaceId || type(IERC165).interfaceId == interfaceId;
    }

    function _transfer(address sender, address receiver, uint256 id, uint256 amount) internal returns (bool) {
        balanceOf[sender][id] -= amount;

        balanceOf[receiver][id] += amount;

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }
}
