// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../types/PoolId.sol";

/// @notice Defines how a raw message is framed, routed and attributed to a source chain.
/// @dev    Deliberately separate from `IMessageGas`: these answers authenticate a message, so they are
///         read from the processor that deserializes it (a Root-filed dependency) rather than from the
///         ops-filed gas service. Splitting them also makes the two views structurally unable to disagree.
interface IMessageParser {
    /// @notice Inspect the message to return the length
    function messageLength(bytes calldata message) external pure returns (uint16);

    /// @notice Inspect the message to return the associated PoolId if any
    function messagePoolId(bytes calldata message) external pure returns (PoolId);

    /// @notice The pool whose adapter set should route/verify the message. Same as `messagePoolId`, except a
    ///         SetPoolAdapters for a pool with no adapter set yet (`poolConfigured == false`) falls back to
    ///         the global pool, so the pool's first adapter configuration can be delivered over the global set.
    function routePoolId(bytes calldata message, bool poolConfigured) external pure returns (PoolId);

    /// @notice Returns the centrifugeId that `message` must originate from, or 0 if any source is permitted.
    function messageSourceCentrifugeId(bytes calldata message) external pure returns (uint16);
}
