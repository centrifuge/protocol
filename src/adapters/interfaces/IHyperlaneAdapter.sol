// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../../admin/interfaces/IAdapterWiring.sol";

// From
// https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/interfaces/hooks/IPostDispatchHook.sol

interface IPostDispatchHook {}

// From
// https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/interfaces/IInterchainSecurityModule.sol

interface IInterchainSecurityModule {
    function moduleType() external view returns (uint8);
}

// From
// https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/interfaces/IMailbox.sol

interface IMailbox {
    /// @notice Dispatches a message to the destination domain & recipient with custom hook and metadata.
    function dispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata body,
        bytes calldata customHookMetadata,
        IPostDispatchHook customHook
    ) external payable returns (bytes32 messageId);

    /// @notice Quotes the fee for dispatching a message with custom hook and metadata.
    function quoteDispatch(
        uint32 destinationDomain,
        bytes32 recipientAddress,
        bytes calldata messageBody,
        bytes calldata customHookMetadata,
        IPostDispatchHook customHook
    ) external view returns (uint256 fee);
}

// From
// https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/interfaces/IMessageRecipient.sol

interface IMessageRecipient {
    /// @notice Called by the Mailbox to deliver a message to the recipient.
    /// @param origin The domain ID of the source chain.
    /// @param sender The address of the sender on the source chain (left-padded bytes32).
    /// @param body The message body.
    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable;
}

// From
// https://github.com/hyperlane-xyz/hyperlane-monorepo/blob/main/solidity/contracts/interfaces/IInterchainSecurityModule.sol

interface ISpecifiesInterchainSecurityModule {
    function interchainSecurityModule() external view returns (IInterchainSecurityModule);
}

struct HyperlaneSource {
    uint16 centrifugeId;
    address addr;
}

struct HyperlaneDestination {
    uint32 hyperlaneDomain;
    address addr;
}

/// @title  IHyperlaneAdapter
/// @notice Cross-chain messaging adapter for Hyperlane
/// @dev    Bridges messages between Centrifuge chains using Hyperlane's interchain messaging protocol
interface IHyperlaneAdapter is IAdapter, IAdapterWiring, IMessageRecipient, ISpecifiesInterchainSecurityModule {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event Wire(uint16 indexed centrifugeId, uint32 indexed hyperlaneDomain, address adapter);
    event SetIsm(address indexed ism);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error NotMailbox();
    error InvalidSource();

    //----------------------------------------------------------------------------------------------
    // Admin methods
    //----------------------------------------------------------------------------------------------

    /// @notice Update the Interchain Security Module used to verify inbound messages
    /// @param ism The new ISM address
    function setIsm(IInterchainSecurityModule ism) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice The MultiAdapter that receives decoded inbound messages from this adapter
    function entrypoint() external view returns (IMessageHandler);

    /// @notice Hyperlane Mailbox used for cross-chain message dispatch and fee quoting
    function mailbox() external view returns (IMailbox);

    /// @notice Returns the source configuration for a given Hyperlane domain ID
    /// @param hyperlaneDomain The remote Hyperlane domain ID
    /// @return centrifugeId The remote chain id
    /// @return addr The address of the remote Hyperlane adapter
    function sources(uint32 hyperlaneDomain) external view returns (uint16 centrifugeId, address addr);

    /// @notice Returns the destination configuration for a given chain id
    /// @param centrifugeId The remote chain id
    /// @return hyperlaneDomain The remote Hyperlane domain ID
    /// @return addr The address of the remote Hyperlane adapter
    function destinations(uint16 centrifugeId) external view returns (uint32 hyperlaneDomain, address addr);
}
