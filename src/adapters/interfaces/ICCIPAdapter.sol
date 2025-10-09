// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC165} from "../../misc/interfaces/IERC7575.sol";

import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";

import {IAdapterWiring} from "../../admin/interfaces/IAdapterWiring.sol";

// Tag to indicate only a gas limit. Only usable for EVM as destination chain.
bytes4 constant EVM_EXTRA_ARGS_V1_TAG = 0x97a657c9;

// From https://github.com/smartcontractkit/chainlink-ccip/blob/main/chains/evm/contracts/libraries/Client.sol#L5
interface IClient {
    /// @dev RMN depends on this struct, if changing, please notify the RMN maintainers.
    struct EVMTokenAmount {
        address token; // token address on the local chain.
        uint256 amount; // Amount of tokens.
    }

    struct Any2EVMMessage {
        bytes32 messageId; // MessageId corresponding to ccipSend on source.
        uint64 sourceChainSelector; // Source chain selector.
        bytes sender; // abi.decode(sender) if coming from an EVM chain.
        bytes data; // payload sent in original message.
        EVMTokenAmount[] destTokenAmounts; // Tokens and their amounts in their destination chain representation.
    }

    // If extraArgs is empty bytes, the default is 200k gas limit.
    struct EVM2AnyMessage {
        bytes receiver; // abi.encode(receiver address) for dest EVM chains.
        bytes data; // Data payload.
        EVMTokenAmount[] tokenAmounts; // Token transfers.
        address feeToken; // Address of feeToken. address(0) means you will send msg.value.
        bytes extraArgs; // Populate this with _argsToBytes(EVMExtraArgsV2).
    }

    struct EVMExtraArgsV1 {
        uint256 gasLimit;
    }
}

// From https://github.com/smartcontractkit/chainlink-ccip/blob/06f2720ee9a0c987a18a9bb226c672adfcf24bcd/chains/evm/contracts/interfaces/IAny2EVMMessageReceiver.sol#L7
interface IAny2EVMMessageReceiver is IERC165 {
    /// @notice Called by the Router to deliver a message. If this reverts, any token transfers also revert.
    /// The message will move to a FAILED state and become available for manual execution.
    /// @param message CCIP Message.
    /// @dev Note ensure you check the msg.sender is the OffRampRouter.
    function ccipReceive(IClient.Any2EVMMessage calldata message) external;
}

// From https://github.com/smartcontractkit/chainlink-ccip/blob/main/chains/evm/contracts/interfaces/IRouterClient.sol#L5C1-L39C2
interface IRouterClient {
    error UnsupportedDestinationChain(uint64 destChainSelector);
    error InsufficientFeeTokenAmount();
    error InvalidMsgValue();

    /// @notice Checks if the given chain ID is supported for sending/receiving.
    /// @param destChainSelector The chain to check.
    /// @return supported is true if it is supported, false if not.
    function isChainSupported(uint64 destChainSelector) external view returns (bool supported);

    /// @param destinationChainSelector The destination chainSelector.
    /// @param message The cross-chain CCIP message including data and/or tokens.
    /// @return fee returns execution fee for the message.
    /// delivery to destination chain, denominated in the feeToken specified in the message.
    /// @dev Reverts with appropriate reason upon invalid message.
    function getFee(uint64 destinationChainSelector, IClient.EVM2AnyMessage memory message)
        external
        view
        returns (uint256 fee);

    /// @notice Request a message to be sent to the destination chain.
    /// @param destinationChainSelector The destination chain ID.
    /// @param message The cross-chain CCIP message including data and/or tokens.
    /// @return messageId The message ID.
    /// @dev Note if msg.value is larger than the required fee (from getFee) we accept.
    /// the overpayment with no refund.
    /// @dev Reverts with appropriate reason upon invalid message.
    function ccipSend(uint64 destinationChainSelector, IClient.EVM2AnyMessage calldata message)
        external
        payable
        returns (bytes32);
}

struct CCIPSource {
    uint16 centrifugeId;
    address addr;
}

struct CCIPDestination {
    uint64 chainSelector;
    address addr;
}

/// @title  ICCIPAdapter
interface ICCIPAdapter is IAdapter, IAdapterWiring, IAny2EVMMessageReceiver {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event Wire(uint16 indexed centrifugeId, uint64 indexed chainSelector, address adapter);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidRouter();
    error InvalidSourceChain();
    error InvalidSourceAddress();
    error InsufficientFeeTokenAmount();
    error RefundFailed();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the source configuration for a given CCIP chain id
    /// @param chainSelector The CCIP chain selector
    /// @return centrifugeId The remote chain id
    /// @return addr Address of the remote CCIP adapter
    function sources(uint64 chainSelector) external view returns (uint16 centrifugeId, address addr);

    /// @notice Returns the destination configuration for a given chain id
    /// @param centrifugeId The remote chain id
    /// @return chainSelector The CCIP chain selector
    /// @return addr The address of the remote CCIP adapter
    function destinations(uint16 centrifugeId) external view returns (uint64 chainSelector, address addr);
}
