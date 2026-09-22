// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IChainlinkAdapter,
    IAdapter,
    ChainlinkSource,
    ChainlinkDestination,
    IRouterClient,
    IClient,
    GENERIC_EXTRA_ARGS_V2_TAG,
    GENERIC_EXTRA_ARGS_V3_TAG,
    WAIT_FOR_FINALITY_FLAG,
    BLOCK_DEPTH_MASK,
    IAny2EVMMessageReceiver,
    IAny2EVMMessageReceiverV2
} from "./interfaces/IChainlinkAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {IERC165} from "../misc/interfaces/IERC7575.sol";

import {IMessageHandler} from "../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";

/// @title  Chainlink Adapter
/// @notice Routing contract that integrates with Chainlink CCIP
/// @dev    Replay protection is enforced by the CCIP stack (Router/OffRamp),
///         which tracks message IDs and prevents duplicate delivery.
contract ChainlinkAdapter is Auth, IChainlinkAdapter {
    /// @dev Cost of executing `ccipReceive()` except entrypoint.handle(), reserved per destination chain.
    ///      Covers 1 cold SLOAD (single-slot `sources` struct) + 1 cold CALL (entrypoint) at 4_700, plus
    ///      a flat 5_300 for dispatch, calldata decode, mapping hash, memory and call setup.
    uint256 public constant DEFAULT_RECEIVE_COST = 10_000;

    uint16 public constant MONAD_CENTRIFUGE_ID = 11;
    // Monad reprices cold storage access (2100→8100) and cold account access (2600→10100) per its
    // published opcode schedule (docs.monad.xyz), putting those same two accesses at 18_200 => +13_500
    // over DEFAULT, wrapper allowance unchanged. Mirrors GasService's per-chain reserve.
    uint256 public constant MONAD_RECEIVE_COST = DEFAULT_RECEIVE_COST + 13_500;

    IRouterClient public immutable ccipRouter;
    IMessageHandler public immutable entrypoint;

    mapping(uint64 chainSelector => ChainlinkSource) public sources;
    mapping(uint16 centrifugeId => ChainlinkDestination) public destinations;

    constructor(IMessageHandler entrypoint_, address ccipRouter_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        ccipRouter = IRouterClient(ccipRouter_);
    }

    //----------------------------------------------------------------------------------------------
    // Network wiring
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterWiring
    function wire(uint16 centrifugeId, bytes memory data) external auth {
        (uint64 chainSelector, address adapter, bytes4 requestedFinality, bytes4 allowedFinality) =
            abi.decode(data, (uint64, address, bytes4, bytes4));
        require(uint32(requestedFinality) & BLOCK_DEPTH_MASK == 0, BlockDepthNotSupported());
        require(uint32(allowedFinality) & BLOCK_DEPTH_MASK == 0, BlockDepthNotSupported());

        sources[chainSelector] = ChainlinkSource(centrifugeId, adapter, allowedFinality);
        destinations[centrifugeId] = ChainlinkDestination(chainSelector, adapter, requestedFinality);
        emit Wire(centrifugeId, chainSelector, adapter, requestedFinality, allowedFinality);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(IClient.Any2EVMMessage calldata message) external {
        require(msg.sender == address(ccipRouter), InvalidRouter());

        ChainlinkSource memory source = sources[message.sourceChainSelector];
        require(source.addr != address(0), InvalidSourceChain());

        address sourceAddress = abi.decode(message.sender, (address));
        require(source.addr == sourceAddress, InvalidSourceAddress());

        entrypoint.handle(source.centrifugeId, message.data);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address)
        external
        payable
        returns (bytes32 adapterData)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        ChainlinkDestination memory destination = destinations[centrifugeId];
        require(destination.chainSelector != 0, UnknownChainId());

        adapterData = ccipRouter.ccipSend{value: msg.value}(
            destination.chainSelector, _createMessage(destination, payload, gasLimit + _receiveCost(centrifugeId))
        );
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        ChainlinkDestination memory destination = destinations[centrifugeId];
        require(destination.chainSelector != 0, UnknownChainId());

        return ccipRouter.getFee(
            destination.chainSelector, _createMessage(destination, payload, gasLimit + _receiveCost(centrifugeId))
        );
    }

    /// @dev Per-destination receive reserve added to the requested gas limit; Monad's cold-access
    ///      repricing needs a larger reserve than other chains.
    function _receiveCost(uint16 centrifugeId) internal pure returns (uint256) {
        return centrifugeId == MONAD_CENTRIFUGE_ID ? MONAD_RECEIVE_COST : DEFAULT_RECEIVE_COST;
    }

    function _createMessage(ChainlinkDestination memory destination, bytes calldata payload, uint256 gasLimit)
        internal
        pure
        returns (IClient.EVM2AnyMessage memory)
    {
        return IClient.EVM2AnyMessage({
            receiver: abi.encode(destination.addr),
            data: payload,
            tokenAmounts: new IClient.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: _extraArgs(destination.requestedFinality, gasLimit)
        });
    }

    function _extraArgs(bytes4 requestedFinality, uint256 gasLimit) internal pure returns (bytes memory) {
        if (requestedFinality == WAIT_FOR_FINALITY_FLAG) {
            return abi.encodeWithSelector(
                GENERIC_EXTRA_ARGS_V2_TAG,
                IClient.GenericExtraArgsV2({gasLimit: gasLimit, allowOutOfOrderExecution: true})
            );
        }

        require(gasLimit <= type(uint32).max, GasLimitTooHigh());
        return abi.encodePacked(GENERIC_EXTRA_ARGS_V3_TAG, uint32(gasLimit), requestedFinality, bytes7(0));
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAny2EVMMessageReceiverV2
    function getCCVsAndFinalityConfig(uint64 sourceChainSelector, bytes calldata)
        external
        view
        returns (address[] memory, address[] memory, uint8, bytes4)
    {
        return (new address[](0), new address[](0), 0, sources[sourceChainSelector].allowedFinality);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId
            || interfaceId == type(IAny2EVMMessageReceiverV2).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
