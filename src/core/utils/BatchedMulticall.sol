// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {IBatchedMulticall} from "./interfaces/IBatchedMulticall.sol";

import {Multicall, IMulticall} from "../../misc/Multicall.sol";

import {IGateway} from "../messaging/interfaces/IGateway.sol";

/// @title  BatchedMulticall
/// @notice Abstract contract that extends Multicall with gateway batching support, enabling efficient
///         aggregation of multiple cross-chain messages into a single batch to reduce transaction costs
///         while coordinating payment handling across batched operations.
abstract contract BatchedMulticall is Multicall, IBatchedMulticall {
    IGateway public gateway;
    address internal transient _sender;

    constructor(IGateway gateway_) {
        gateway = gateway_;
    }

    /// @inheritdoc IMulticall
    /// @notice With extra support for batching
    function multicall(bytes[] calldata data) public payable override {
        require(!gateway.isBatching(), IGateway.AlreadyBatching());

        _sender = msg.sender;
        gateway.withBatch{value: msg.value}(
            abi.encodeWithSelector(BatchedMulticall.executeMulticall.selector, data), msg.sender
        );
        _sender = address(0);
    }

    function executeMulticall(bytes[] calldata data) external payable protected {
        gateway.lockCallback();
        super.multicall(data);
    }

    function msgSender() internal view virtual returns (address) {
        return _sender != address(0) ? _sender : msg.sender;
    }

    /// @dev gives the current msg.value depending on the batching state
    function _payment() internal view returns (uint256 value) {
        return _sender != address(0) ? 0 : msg.value;
    }
}
