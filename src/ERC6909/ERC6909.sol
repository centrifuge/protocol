// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IERC6909} from "src/interfaces/ERC6909/IERC6909.sol";
import {IERC165} from "src/interfaces/IERC165.sol";
import {StringLib} from "src/libraries/StringLib.sol";

/// @title      Basic implementation of all properties according to the ERC6909.
///
/// @dev        This implementation MUST be extended with another contract which defines how tokens are created.
///             Either implement mint/burn or override transfer/transferFrom.
abstract contract ERC6909 is IERC6909 {
    mapping(address owner => mapping(uint256 tokenId => uint256)) public balanceOf;
    mapping(address owner => mapping(address operator => bool)) public isOperator;
    mapping(address owner => mapping(address spender => mapping(uint256 tokenId => uint256))) public allowance;

    /// @inheritdoc IERC6909
    function transfer(address receiver, uint256 tokenId, uint256 amount) external virtual returns (bool) {
        return _transfer(msg.sender, receiver, tokenId, amount);
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
                require(amount <= allowed, InsufficientAllowance(msg.sender, tokenId));
                allowance[sender][msg.sender][tokenId] -= amount;
            }
        }

        return _transfer(sender, receiver, tokenId, amount);
    }

    /// @inheritdoc IERC6909
    function approve(address spender, uint256 tokenId, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender][tokenId] = amount;

        emit Approval(msg.sender, spender, tokenId, amount);

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

    function _mint(address owner, uint256 tokenId, uint256 amount) internal {
        require(owner != address(0), EmptyOwner());
        require(tokenId > 0, InvalidTokenId());
        require(amount > 0, EmptyAmount());

        balanceOf[owner][tokenId] += amount;

        emit Transfer(msg.sender, address(0), owner, tokenId, amount);
    }

    function _burn(address owner, uint256 tokenId, uint256 amount) internal {
        uint256 balance = balanceOf[owner][tokenId];
        require(balance >= amount, InsufficientBalance(msg.sender, tokenId));

        // The underflow check is handled by the require line above
        unchecked {
            balanceOf[owner][tokenId] -= amount;
        }

        emit Transfer(owner, owner, address(0), tokenId, amount);
    }

    function _transfer(address sender, address receiver, uint256 tokenId, uint256 amount) private returns (bool) {
        uint256 senderBalance = balanceOf[sender][tokenId];
        require(senderBalance >= amount, InsufficientBalance(sender, tokenId));

        //        The require check few lines above guarantees that
        //        it cannot underflow.
        unchecked {
            balanceOf[sender][tokenId] -= amount;
        }

        balanceOf[receiver][tokenId] += amount;

        emit Transfer(msg.sender, sender, receiver, tokenId, amount);

        return true;
    }
}
