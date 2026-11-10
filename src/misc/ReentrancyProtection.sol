// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

// NOTE: This file has warning disabled due https://github.com/ethereum/solidity/issues/14359
// If perform any change on it, please ensure no other warnings appears

/// @title  ReentrancyProtection
/// @notice Abstract contract that implements reentrancy protection using transient storage, in two strengths:
///         `protected`, which lets the initiating sender back in so a multicall can batch protected methods,
///         and the strict `nonReentrant`, which lets nobody back in.
/// @dev    Use the strict lock where the caller and an untrusted callee can be the same account: `protected`
///         admits a re-entrant call from the initiator whether or not a multicall is involved.
abstract contract ReentrancyProtection {
    /// @notice Dispatched when there is a re-entrancy issue
    error UnauthorizedSender();

    /// @notice Dispatched when a strictly locked method is re-entered
    error Reentrancy();

    address private transient _initiator;
    bool private transient _entered;

    /// @dev The method is protected for reentrancy issues.
    modifier protected() {
        if (_initiator == address(0)) {
            // Single call re-entrancy lock
            _initiator = msg.sender;
            _;
            _initiator = address(0);
        } else {
            // Multicall re-entrancy lock
            require(msg.sender == _initiator, UnauthorizedSender());
            _;
        }
    }

    /// @dev The method cannot be re-entered, by anyone.
    modifier nonReentrant() {
        require(!_entered, Reentrancy());
        _entered = true;
        _;
        _entered = false;
    }
}
