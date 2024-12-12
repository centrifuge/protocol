// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "forge-std/interfaces/IERC165.sol";

interface IERC6909 is IERC165 {
    /// Errors
    error EmptyOwner();
    error EmptyAmount();
    error InvalidTokenId();
    error InsufficientBalance(address owner, uint256 tokenId);
    error InsufficientAllowance(address sender, uint256 tokenId);

    /// Events
    event OperatorSet(address indexed owner, address indexed operator, bool approved);
    event Approval(address indexed owner, address indexed spender, uint256 indexed tokenId, uint256 amount);
    event Transfer(address caller, address indexed from, address indexed to, uint256 indexed tokenId, uint256 amount);

    /// Functions
    /// @notice           Owner balance of a tokenId.
    /// @param owner      The address of the owner.
    /// @param tokenId    The id of the token.
    /// @return amount    The balance of the token.
    function balanceOf(address owner, uint256 tokenId) external view returns (uint256 amount);

    /// @notice           Spender allowance of a tokenId.
    /// @param owner      The address of the owner.
    /// @param spender    The address of the spender.
    /// @param tokenId    The id of the token.
    /// @return amount    The allowance of the token.
    function allowance(address owner, address spender, uint256 tokenId) external view returns (uint256 amount);

    /// @notice           Checks if a spender is approved by an owner as an operator.
    /// @param owner      The address of the owner.
    /// @param spender    The address of the spender.
    /// @return approved  The approval status.
    function isOperator(address owner, address spender) external view returns (bool approved);

    /// @notice           Transfers an amount of a tokenId from the caller to a receiver.
    /// @param receiver   The address of the receiver.
    /// @param tokenId    The id of the token.
    /// @param amount     The amount of the token.
    /// @return bool      True, always, unless the function reverts.
    function transfer(address receiver, uint256 tokenId, uint256 amount) external returns (bool);

    /// @notice           Transfers an amount of a tokenId from a sender to a receiver.
    /// @param sender     The address of the sender.
    /// @param receiver   The address of the receiver.
    /// @param tokenId    The id of the token.
    /// @param amount     The amount of the token.
    /// @return bool      True, always, unless the function reverts.
    function transferFrom(address sender, address receiver, uint256 tokenId, uint256 amount) external returns (bool);

    /// @notice           Approves an amount of a tokenId to a spender.
    /// @param spender    The address of the spender.
    /// @param tokenId    The id of the token.
    /// @param amount     The amount of the token.
    /// @return bool      True, always.
    function approve(address spender, uint256 tokenId, uint256 amount) external returns (bool);

    /// @notice           Sets or removes an operator for the caller.
    /// @param operator   The address of the operator.
    /// @param approved   The approval status.
    /// @return bool      True, always.
    function setOperator(address operator, bool approved) external returns (bool);
}
