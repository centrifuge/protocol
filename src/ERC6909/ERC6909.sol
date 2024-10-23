// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {
    ERC6909_Transfer_InsufficientBalance,
    ERC6909_TransferFrom_InsufficientAllowance
} from "src/ERC6909/ERC6909Errors.sol";
import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC165} from "src/interfaces/IERC165.sol";
import {OverflowUint256} from "src/Errors.sol";

/// @title      Basic implementation of all properties according to the ERC6909.
///
/// @dev        This implementation MUST be extended with another contract which defines how tokens are created
///             Either implement mint/burn or override transfer/transferFrom
abstract contract ERC6909 is IERC6909, IERC165 {
    mapping(address owner => mapping(uint256 id => uint256 amount)) public balanceOf;
    mapping(address owner => mapping(address operator => bool isOperator)) public isOperator;
    mapping(address owner => mapping(address spender => mapping(uint256 id => uint256 amount))) public allowance;

    /// @inheritdoc IERC6909
    function transfer(address receiver, uint256 id, uint256 amount) external virtual returns (bool) {
        return _transfer(msg.sender, receiver, id, amount);
    }

    /// @inheritdoc IERC6909
    function transferFrom(address sender, address receiver, uint256 tokenId, uint256 amount)
        external
        virtual
        returns (bool)
    {
        if (msg.sender != sender && !isOperator[sender][msg.sender]) {
            uint256 allowed = allowance[sender][msg.sender][tokenId];
            if (allowed != type(uint256).max) {
                unchecked {
                    uint256 newAllowance = allowed - amount;
                    require(newAllowance <= allowed, ERC6909_TransferFrom_InsufficientAllowance(msg.sender, tokenId));
                    allowance[sender][msg.sender][tokenId] = newAllowance;
                }
            }
        }

        return _transfer(sender, receiver, tokenId, amount);
    }

    /// @inheritdoc IERC6909
    function approve(address spender, uint256 id, uint256 amount) external returns (bool) {
        if (allowance[msg.sender][spender][id] != amount) {
            allowance[msg.sender][spender][id] = amount;

            emit Approval(msg.sender, spender, id, amount);
        }
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

    function _transfer(address sender, address receiver, uint256 id, uint256 amount) private returns (bool) {
        uint256 senderBalance = balanceOf[sender][id];
        require(senderBalance >= amount, ERC6909_Transfer_InsufficientBalance(sender, id));

        /// @dev    The require check few lines above guarantees that
        ///         it cannot underflow.
        unchecked {
            balanceOf[sender][id] -= amount;
        }

        /// @dev    The totalSupply check during minting guarantees that
        ///         there won't be more token that will cause overflow
        unchecked {
            balanceOf[receiver][id] += amount;
        }

        emit Transfer(msg.sender, sender, receiver, id, amount);

        return true;
    }
}
