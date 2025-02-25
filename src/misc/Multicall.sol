// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMulticall} from "src/misc/interfaces/IMulticall.sol";

abstract contract Multicall is IMulticall {
    address public transient initiator;

    modifier protected() {
        if (initiator == address(0)) {
            // Single call re-entrancy lock
            initiator = msg.sender;
            _;
            initiator = address(0);
        } else {
            // Multicall re-entrancy lock
            require(msg.sender == initiator, UnauthorizedSender());
            _;
        }
    }

    function multicall(bytes[] calldata data) external payable {
        require(initiator == address(0), AlreadyInitiated());

        initiator = msg.sender;

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

        initiator = address(0);
    }
}
