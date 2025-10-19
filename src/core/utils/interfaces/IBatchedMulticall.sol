// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IGateway} from "../../messaging/interfaces/IGateway.sol";

/// @notice A multicall that batches the messages using the gateway
interface IBatchedMulticall {
    error AlreadyBatching();

    /// @notice Returns the gateway contract used for batching messages
    /// @return The gateway contract instance
    function gateway() external view returns (IGateway);
}
