// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../../admin/interfaces/IAdapterWiring.sol";

// From
// https://github.com/polymerdao/prover-contracts/blob/main/contracts/interfaces/ICrossL2ProverV2.sol

interface ICrossL2ProverV2 {
    /// @notice Validates an event proof and returns the decoded log data.
    /// @param proof The proof bytes returned from the Polymer prove API.
    /// @return chainId The source chain ID that emitted the event
    /// @return emittingContract The address of the contract that emitted the event
    /// @return topics The event topics (first is event signature, rest are indexed params)
    /// @return unindexedData The ABI-encoded non-indexed event parameters
    function validateEvent(bytes calldata proof)
        external
        view
        returns (uint32 chainId, address emittingContract, bytes calldata topics, bytes calldata unindexedData);
}

struct PolymerSource {
    uint16 centrifugeId;
    address addr;
}

struct PolymerDestination {
    uint32 polymerChainId;
    address addr;
}

/// @title  IPolymerAdapter
/// @notice Cross-chain messaging adapter for Polymer
/// @dev    Bridges messages between Centrifuge chains using Polymer's event-proving protocol.
///         Outbound messages are emitted as events; inbound messages are validated via the
///         CrossL2ProverV2 contract with a proof supplied by an off-chain relayer.
interface IPolymerAdapter is IAdapter, IAdapterWiring {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event Wire(uint16 indexed centrifugeId, uint32 indexed polymerChainId, address adapter);

    /// @notice Emitted on the source chain for the off-chain relayer to pick up and prove
    ///         on the destination chain.
    /// @param centrifugeId The destination Centrifuge chain ID
    /// @param adapter The destination adapter address
    /// @param nonce Monotonically increasing nonce for replay protection
    /// @param payload The message payload
    event SendMessage(uint16 indexed centrifugeId, address indexed adapter, uint256 indexed nonce, bytes payload);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidProof();
    error InvalidSource();
    error AlreadyProcessed();

    //----------------------------------------------------------------------------------------------
    // Receive
    //----------------------------------------------------------------------------------------------

    /// @notice Receive a cross-chain message by submitting a Polymer proof.
    ///         Permissionless: anyone can relay proofs.
    /// @param proof The proof bytes from the Polymer prove API
    function receiveMessage(bytes calldata proof) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice The MultiAdapter that receives decoded inbound messages from this adapter
    function entrypoint() external view returns (IMessageHandler);

    /// @notice Polymer CrossL2ProverV2 used to validate event proofs
    function prover() external view returns (ICrossL2ProverV2);

    /// @notice Current outbound nonce (incremented on each send)
    function currentNonce() external view returns (uint256);

    /// @notice Returns whether a given nonce from a given source has been processed
    /// @param polymerChainId The source Polymer chain ID
    /// @param nonce_ The message nonce
    /// @return True if the nonce has already been processed
    function processedNonces(uint32 polymerChainId, uint256 nonce_) external view returns (bool);

    /// @notice Returns the source configuration for a given Polymer chain ID
    /// @param polymerChainId The remote Polymer chain ID
    /// @return centrifugeId The remote Centrifuge chain id
    /// @return addr The address of the remote Polymer adapter
    function sources(uint32 polymerChainId) external view returns (uint16 centrifugeId, address addr);

    /// @notice Returns the destination configuration for a given Centrifuge chain ID
    /// @param centrifugeId The remote Centrifuge chain id
    /// @return polymerChainId The remote Polymer chain ID
    /// @return addr The address of the remote Polymer adapter
    function destinations(uint16 centrifugeId) external view returns (uint32 polymerChainId, address addr);
}
