// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice Defines methods to get properties from raw messages
interface IMessageProperties {
    /// @notice Gas limit for the execution cost of an individual message in a remote chain from the adapter.
    /// @dev    NOTE: In the future we could want to dispatch:
    ///         - by destination chain (for non-EVM chains)
    ///         - by message type
    ///         - by inspecting the payload checking different subsmessages that alter the endpoint processing
    /// @param centrifugeId Where to the cost is defined
    /// @param message Individual message
    /// @return Estimated cost in WEI units
    function messageOverallGasLimit(uint16 centrifugeId, bytes calldata message) external view returns (uint128);

    /// @notice Similar to messageOverallGasLimit but taking only into account the exact gas to process it from the Gateway
    ///         for processing the message without any extra addition
    function messageProcessingGasLimit(uint16 centrifugeId, bytes calldata message) external view returns (uint128);

    /// @notice Maximum Gas limit for a batch, determined how much the destination chain can process
    /// @param centrifugeId Destination where to the maximum cost is defined
    function maxBatchGasLimit(uint16 centrifugeId) external view returns (uint128);

    /// @notice Inspect the message to return the length
    function messageLength(bytes calldata message) external view returns (uint16);

    /// @notice Inspect the message to return the associated PoolId if any
    function messagePoolId(bytes calldata message) external pure returns (PoolId);

    /// @notice The pool whose adapter set should route/verify the message. Same as `messagePoolId`, except a
    ///         SetPoolAdapters for a pool with no adapter set yet (`poolConfigured == false`) falls back to
    ///         the global pool, so the pool's first adapter configuration can be delivered over the global set.
    function routePoolId(bytes calldata message, bool poolConfigured) external pure returns (PoolId);

    /// @notice Returns the centrifugeId that `message` must originate from, or 0 if any source is permitted.
    function messageSourceCentrifugeId(bytes calldata message) external pure returns (uint16);

    /// @notice Gas reserved in every message budget to handle a worst-case processor revert.
    function messageFailureGasReserve() external view returns (uint128);
}
