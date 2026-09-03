// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageHandler} from "./IMessageHandler.sol";

/// @notice Thin entrypoint that adapters use to reach the MultiAdapter. Extends {IMessageHandler} (the regular
///         vote-and-maybe-execute path) with the proof-adapter primitives {vote} and {execute}, which decouple
///         voting from execution. Adapters depend on this small interface instead of the full {IMultiAdapter}.
interface IAdapterEntrypoint is IMessageHandler {
    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when {execute} is called for a payload whose votes have not reached the threshold
    ///         (i.e. some required adapter has not delivered its proof yet).
    error NotEnoughVotes();

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @notice Records the calling adapter's vote for `payload` WITHOUT ever executing it, even once the
    ///         threshold is reached. Proof adapters call this on receipt; execution is deferred to {execute}.
    /// @dev    Unlike `handle()`, this never forwards to the gateway and never consumes votes, so a cheap proof
    ///         delivery can never trigger an under-funded inline execution.
    /// @param  centrifugeId Source chain identifier
    /// @param  payload The wrapped payload (session-id prefixed) to vote on
    function vote(uint16 centrifugeId, bytes calldata payload) external;

    /// @notice Executes a payload whose votes have already reached the threshold,
    ///         consuming the quorum's votes. Does NOT cast a vote of its own.
    /// @dev    Reverts with {NotEnoughVotes} if the threshold is not met.
    /// @param  centrifugeId Source chain identifier
    /// @param  payload The wrapped payload (session-id prefixed) to execute
    function execute(uint16 centrifugeId, bytes calldata payload) external;
}
