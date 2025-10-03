// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.28;

import {Multicall, IMulticall} from "../../misc/Multicall.sol";

import {IGateway} from "../interfaces/IGateway.sol";
import {IBatchedMulticall} from "../interfaces/IBatchedMulticall.sol";

abstract contract BatchedMulticall is Multicall, IBatchedMulticall {
    IGateway public gateway;
    bool internal transient _isBatching;

    constructor(IGateway gateway_) {
        gateway = gateway_;
    }

    /// @inheritdoc IMulticall
    /// @notice With extra support for batching
    function multicall(bytes[] calldata data) public payable override protected {
        require(!gateway.isBatching(), IGateway.AlreadyBatching());

        _isBatching = true;
        gateway.startBatching();

        super.multicall(data);

        gateway.endBatching{value: msg.value}(msg.sender);
        _isBatching = false;
    }

    /// @dev gives the current msg.value depending on the batching state
    function _payment() internal view returns (uint256 value) {
        return _isBatching ? 0 : msg.value;
    }
}
