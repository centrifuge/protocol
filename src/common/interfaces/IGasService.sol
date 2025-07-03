// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev Max cost. No messages will take more that this
uint128 constant MAX_MESSAGE_COST = 3_000_000;

interface IGasService {
    /// @notice Gas limit for the execution cost of an individual message in a remote chain.
    /// @dev    NOTE: In the future we could want to dispatch:
    ///         - by destination chain (for non-EVM chains)
    ///         - by message type
    ///         - by inspecting the payload checking different subsmessages that alter the endpoint processing
    /// @param centrifugeId Where to the cost is defined
    /// @param message Individual message
    /// @return Estimated cost in WEI units
    function messageGasLimit(uint16 centrifugeId, bytes calldata message) external view returns (uint128);

    /// @notice Gas limit for the execution cost of a batch in a remote chain.
    /// @param centrifugeId Where to the cost is defined
    /// @return Max cost in WEI units
    function batchGasLimit(uint16 centrifugeId) external view returns (uint128);
}
