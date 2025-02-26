// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

// NOTE: This file has warning disabled due https://github.com/ethereum/solidity/issues/14359
// If perform any change on it, please ensure no other warnings appears

import {IMulticall} from "src/misc/interfaces/IMulticall.sol";

abstract contract Multicall is IMulticall {
    address private transient _initiator;

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

    function multicall(bytes[] calldata data) public payable {
        require(_initiator == address(0), AlreadyInitiated());

        _initiator = msg.sender;

        uint256 totalBytes = data.length;
        for (uint256 i; i < totalBytes; ++i) {
            (bool success, bytes memory returnData) = address(this).delegatecall(data[i]);
            if (!success) {
                uint256 length = returnData.length;
                require(length != 0, CallFailed());

                assembly ("memory-safe") {
                    revert(add(32, returnData), length)
                }
            }
        }

        _initiator = address(0);
    }
}
