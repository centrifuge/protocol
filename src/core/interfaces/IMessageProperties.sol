// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../types/PoolId.sol";

/// @notice Defines methods to get properties from raw messages
interface IMessageProperties {
    /// @notice Gas limit for the execution cost of an individual message in a remote chain.
    /// @dev    NOTE: In the future we could want to dispatch:
    ///         - by destination chain (for non-EVM chains)
    ///         - by message type
    ///         - by inspecting the payload checking different subsmessages that alter the endpoint processing
    /// @param centrifugeId Where to the cost is defined
    /// @param message Individual message
    /// @return Estimated cost in WEI units
    function gasLimit(uint16 centrifugeId, bytes calldata message) external view returns (uint128);

    /// @notice Inspect the message to return the length
    function length(bytes calldata message) external pure returns (uint16);

    /// @notice Inspect the message to return the associated PoolId if any
    function poolId(bytes calldata message) external pure returns (PoolId);
}
