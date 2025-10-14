// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

// NOTE: This file has warning disabled due https://github.com/ethereum/solidity/issues/14359
// If perform any change on it, please ensure no other warnings appears

/// @title  ReentrancyProtection
/// @notice Abstract contract that implements reentrancy protection using transient storage.
abstract contract ReentrancyProtection {
    /// @notice Dispatched when there is a re-entrancy issue
    error UnauthorizedSender(address expected, address actual);

    address private transient _initiator;
    address internal transient _multicallSource;

    /// @dev The method is protected for reentrancy issues.
    modifier protected() {
        if (_initiator == address(0)) {
            // Single call re-entrancy lock
            _initiator = msg.sender;
            _;
            _initiator = address(0);
        } else {
            // Multicall re-entrancy lock
            require(
                _multicallSource != address(0) ? msg.sender == _multicallSource : msg.sender == _initiator,
                UnauthorizedSender(_multicallSource != address(0) ? _multicallSource : _initiator, msg.sender)
            );
            _;
        }
    }

    function msgSender() internal view virtual returns (address) {
        return _initiator != address(0) ? _initiator : msg.sender;
    }
}
