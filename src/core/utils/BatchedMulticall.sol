// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IBatchedMulticall} from "./interfaces/IBatchedMulticall.sol";

import {Multicall, IMulticall} from "../../misc/Multicall.sol";

import {CrosschainBatcher} from "../messaging/CrosschainBatcher.sol";

/// @title  BatchedMulticall
/// @notice Abstract contract that extends Multicall with gateway batching support, enabling efficient
///         aggregation of multiple cross-chain messages into a single batch to reduce transaction costs
///         while coordinating payment handling across batched operations.
/// @dev    Integrators MUST replace msg.sender with msgSender().
abstract contract BatchedMulticall is Multicall, IBatchedMulticall {
    CrosschainBatcher public batcher;
    address private transient _sender;

    constructor(CrosschainBatcher batcher_) {
        batcher = batcher_;
    }

    /// @inheritdoc IMulticall
    /// @notice     With extra support for batching
    function multicall(bytes[] calldata data) public payable override {
        _sender = msg.sender;
        batcher.withBatch{
            value: msg.value
        }(abi.encodeWithSelector(BatchedMulticall.executeMulticall.selector, data), msg.sender);
        _sender = address(0);
    }

    function executeMulticall(bytes[] calldata data) external payable protected {
        batcher.lockCallback();
        super.multicall(data);
    }

    /// @dev Integrators MUST use msgSender() instead of msg.sender, since this is replaced
    ///      by the gateway address inside the multicall.
    function msgSender() internal view virtual returns (address) {
        return _sender != address(0) ? _sender : msg.sender;
    }

    /// @dev Only the call to multicall should pass the msg.value, which is then passed
    ///      in `gateway.withBatch`. No inner calls should pass any msg.value.
    function msgValue() internal view returns (uint256 value) {
        return _sender != address(0) ? 0 : msg.value;
    }
}
