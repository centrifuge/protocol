// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../misc/Auth.sol";

import {IAdapter} from "../core/interfaces/IAdapter.sol";
import {IMessageHandler} from "../core/interfaces/IMessageHandler.sol";

/// @notice An adapter used to recover messages. It skips any outgoing message.
contract RecoveryAdapter is Auth, IAdapter, IMessageHandler {
    IMessageHandler public immutable entrypoint;

    constructor(IMessageHandler entrypoint_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 centrifugeId, bytes calldata message) external auth {
        entrypoint.handle(centrifugeId, message);
    }

    /// @inheritdoc IAdapter
    function send(uint16, bytes calldata, uint256, address) external payable returns (bytes32 adapterData) {
        return "";
    }

    /// @inheritdoc IAdapter
    function estimate(uint16, bytes calldata, uint256) external pure returns (uint256) {
        return 0;
    }

    /// @inheritdoc IAdapter
    /// @dev RecoveryAdapter is a local recovery mechanism, not a cross-chain adapter
    function wire(bytes memory) external pure {
        revert("RecoveryAdapter: wire not supported");
    }

    /// @inheritdoc IAdapter
    /// @dev RecoveryAdapter is a local recovery mechanism, not a cross-chain adapter
    function isWired(uint16) external pure returns (bool) {
        revert("RecoveryAdapter: isWired not supported");
    }
}
