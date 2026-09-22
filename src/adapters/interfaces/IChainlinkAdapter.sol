// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC165} from "../../misc/interfaces/IERC7575.sol";

import {IAdapter} from "../../core/messaging/interfaces/IAdapter.sol";
import {IAdapterEntrypoint} from "../../core/messaging/interfaces/IAdapterEntrypoint.sol";

import {IAdapterWiring} from "../../admin/interfaces/IAdapterWiring.sol";

// Tag to indicate a gas limit (or dest chain equivalent processing units) and Out Of Order Execution. This tag is
// available for multiple chain families. If there is no chain family specific tag, this is the default available
// for a chain.
// Note: not available for Solana VM based chains.
bytes4 constant GENERIC_EXTRA_ARGS_V2_TAG = 0x181dcf10;

// The extra args CCIP 2.0 introduced. The struct version runs one ahead of the CCIP version: CCIP 1.5 uses
// GenericExtraArgsV2 above, CCIP 2.0 uses GenericExtraArgsV3. Here V2 and V3 always name the struct, 1.5 and 2.0
// always name the CCIP version.
// V3 replaces `allowOutOfOrderExecution` (always on in CCIP 2.0) with a requested finality config, and narrows the
// gas limit to uint32.
// From https://github.com/smartcontractkit/chainlink-ccip/blob/main/chains/evm/contracts/libraries/ExtraArgsCodec.sol
bytes4 constant GENERIC_EXTRA_ARGS_V3_TAG = 0xa69dd4aa;

// A finality config is a bytes4: the low 16 bits are a block depth, the high 16 bits are flags. Zero means wait for
// full finality, and is what every CCIP version before 2.0 does unconditionally.
// From https://github.com/smartcontractkit/chainlink-ccip/blob/main/chains/evm/contracts/libraries/FinalityCodec.sol
bytes4 constant WAIT_FOR_FINALITY_FLAG = bytes4(0);

// The low 16 bits of a finality config, the block-depth half. `wire` refuses any value that sets them.
uint32 constant BLOCK_DEPTH_MASK = 0xFFFF;

// Bit 16: wait for the `safe` head rather than for finality. This is what the Fast Confirmation Rule (FCR) asks for,
// one slot (~13s) instead of two epochs (~13min). No CCIP lane permits it yet.
bytes4 constant WAIT_FOR_SAFE_FLAG = bytes4(uint32(1 << 16));

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

    /// @param gasLimit: gas limit for the callback on the destination chain.
    /// @param allowOutOfOrderExecution: if true, it indicates that the message can be executed in any order relative to
    /// other messages from the same sender. This value's default varies by chain. On some chains, a particular value is
    /// enforced, meaning if the expected value is not set, the message request will revert.
    /// @dev Fully compatible with the previously existing EVMExtraArgsV2.
    struct GenericExtraArgsV2 {
        uint256 gasLimit;
        bool allowOutOfOrderExecution;
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

// From https://github.com/smartcontractkit/chainlink-ccip/blob/main/chains/evm/contracts/interfaces/IAny2EVMMessageReceiverV2.sol
interface IAny2EVMMessageReceiverV2 is IAny2EVMMessageReceiver {
    /// @notice Get the CCV configuration & allowed finality config for a source chain and sender.
    /// @dev A receiver that does not implement this is treated as accepting fully finalized messages only, so this is
    /// the inbound half of opting into faster-than-finality delivery.
    /// @param sourceChainSelector The source chain selector of the incoming message.
    /// @param sender The sender of the message on the source chain.
    /// @return requiredCCVs Verifiers that must all pass. Empty means the lane's defaults.
    /// @return optionalCCVs Verifiers that may contribute to validation.
    /// @return optionalThreshold How many of `optionalCCVs` must pass.
    /// @return allowedFinalityConfig The finality configs accepted from this source.
    function getCCVsAndFinalityConfig(uint64 sourceChainSelector, bytes calldata sender)
        external
        view
        returns (
            address[] memory requiredCCVs,
            address[] memory optionalCCVs,
            uint8 optionalThreshold,
            bytes4 allowedFinalityConfig
        );
}

// From https://github.com/smartcontractkit/chainlink-ccip/blob/main/chains/evm/contracts/interfaces/IRouterClient.sol#L5C1-L39C2
interface IRouterClient {
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

// Both structs are one slot, which `ChainlinkAdapter.DEFAULT_RECEIVE_COST` assumes when it reserves a single cold
// SLOAD for the inbound path.
struct ChainlinkSource {
    uint16 centrifugeId;
    address addr;
    bytes4 allowedFinality;
}

struct ChainlinkDestination {
    uint64 chainSelector;
    address addr;
    bytes4 requestedFinality;
}

/// @title  IChainlinkAdapter
/// @dev    `wire` takes `abi.encode(uint64 chainSelector, address adapter, bytes4 requestedFinality,
///         bytes4 allowedFinality)`.
///
///         The two finality fields are independent and both default to zero, full finality, which is what every CCIP
///         version does unconditionally. `requestedFinality` is what this adapter asks of CCIP when sending: zero
///         keeps the V2 extra args, which every lane understands, and anything else sends V3 extra args, whose tag
///         a lane still on CCIP 1.5 rejects. `allowedFinality` is what it accepts when receiving.
///
///         Zero is the only value safe to wire blindly. A lane is moved off it once that lane is known to be on CCIP
///         2.0, which is a per-lane fact: sending V3 extra args to a CCIP 1.5 lane reverts.
///
///         CCIP takes two faster-than-finality modes and this adapter passes both through unvalidated, so what is
///         wired is a policy question rather than a compiled-in one. A block depth, `bytes4(uint32(n))`, asks for n
///         confirmations: a bet that no reorg runs deeper, with nothing backing it and nothing forfeited when it
///         fails. `WAIT_FOR_SAFE_FLAG` asks for the `safe` head, the Fast Confirmation Rule, which is deterministic
///         under synchrony and below roughly a quarter adversarial stake. Weaker than finality, whose guarantee is
///         that reverting costs a third of all staked ETH, but a guarantee rather than a bet.
///
///         Only the two ends of that range are meant to be wired, zero or `WAIT_FOR_SAFE_FLAG`, and the deploy and
///         wiring tooling is where that is enforced. No lane permits the safe flag yet.
interface IChainlinkAdapter is IAdapter, IAdapterWiring, IAny2EVMMessageReceiverV2 {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event Wire(
        uint16 indexed centrifugeId,
        uint64 indexed chainSelector,
        address adapter,
        bytes4 requestedFinality,
        bytes4 allowedFinality
    );

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidRouter();
    error InvalidSourceChain();
    error InvalidSourceAddress();
    error GasLimitTooHigh();
    error BlockDepthNotSupported();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Chainlink's CCIP router used for cross-chain message dispatch and fee estimation
    function ccipRouter() external view returns (IRouterClient);

    /// @notice The MultiAdapter that receives decoded inbound messages from this adapter
    function entrypoint() external view returns (IAdapterEntrypoint);

    /// @notice Returns the source configuration for a given Chainlink chain id
    /// @param chainSelector The Chainlink chain selector
    /// @return centrifugeId The remote chain id
    /// @return addr Address of the remote Chainlink adapter
    /// @return allowedFinality The finality configs accepted from this source
    function sources(uint64 chainSelector)
        external
        view
        returns (uint16 centrifugeId, address addr, bytes4 allowedFinality);

    /// @notice Returns the destination configuration for a given chain id
    /// @param centrifugeId The remote chain id
    /// @return chainSelector The Chainlink chain selector
    /// @return addr The address of the remote Chainlink adapter
    /// @return requestedFinality The finality asked of CCIP for messages sent to this destination
    function destinations(uint16 centrifugeId)
        external
        view
        returns (uint64 chainSelector, address addr, bytes4 requestedFinality);
}
