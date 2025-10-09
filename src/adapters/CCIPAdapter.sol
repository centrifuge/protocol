// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    ICCIPAdapter,
    IAdapter,
    CCIPSource,
    CCIPDestination,
    IRouterClient,
    IClient,
    EVM_EXTRA_ARGS_V1_TAG,
    IAny2EVMMessageReceiver
} from "./interfaces/ICCIPAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {IERC165} from "../misc/interfaces/IERC7575.sol";

import {IMessageHandler} from "../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";

/// @title  CCIP Adapter
/// @notice Routing contract that integrates with Chainlink CCIP
contract CCIPAdapter is Auth, ICCIPAdapter {
    using CastLib for *;

    /// @dev Cost of executing `ccipReceive()` except entrypoint.handle()
    uint256 public constant RECEIVE_COST = 4000;

    IRouterClient public immutable ccipRouter;
    IMessageHandler public immutable entrypoint;

    mapping(uint64 chainSelector => CCIPSource) public sources;
    mapping(uint16 centrifugeId => CCIPDestination) public destinations;

    constructor(IMessageHandler entrypoint_, address ccipRouter_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        ccipRouter = IRouterClient(ccipRouter_);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterWiring
    function wire(uint16 centrifugeId, bytes memory data) external auth {
        (uint64 chainSelector, address adapter) = abi.decode(data, (uint64, address));
        sources[chainSelector] = CCIPSource(centrifugeId, adapter);
        destinations[centrifugeId] = CCIPDestination(chainSelector, adapter);
        emit Wire(centrifugeId, chainSelector, adapter);
    }

    /// @inheritdoc IAdapterWiring
    function isWired(uint16 centrifugeId) external view returns (bool) {
        return destinations[centrifugeId].chainSelector != 0;
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAny2EVMMessageReceiver
    function ccipReceive(IClient.Any2EVMMessage calldata message) external {
        require(msg.sender == address(ccipRouter), InvalidRouter());

        CCIPSource memory source = sources[message.sourceChainSelector];
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
        CCIPDestination memory destination = destinations[centrifugeId];
        require(destination.chainSelector != 0, UnknownChainId());

        adapterData = ccipRouter.ccipSend{value: msg.value}(
            destination.chainSelector, _createMessage(destination, payload, gasLimit)
        );
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        CCIPDestination memory destination = destinations[centrifugeId];
        require(destination.chainSelector != 0, UnknownChainId());

        return ccipRouter.getFee(destination.chainSelector, _createMessage(destination, payload, gasLimit));
    }

    function _createMessage(CCIPDestination memory destination, bytes calldata payload, uint256 gasLimit)
        internal
        pure
        returns (IClient.EVM2AnyMessage memory)
    {
        return IClient.EVM2AnyMessage({
            receiver: abi.encode(destination.addr),
            data: payload,
            tokenAmounts: new IClient.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: _argsToBytes(IClient.EVMExtraArgsV1({gasLimit: gasLimit + RECEIVE_COST}))
        });
    }

    // Based on https://github.com/smartcontractkit/chainlink-ccip/blob/06f2720ee9a0c987a18a9bb226c672adfcf24bcd/chains/evm/contracts/libraries/Client.sol#L36
    function _argsToBytes(IClient.EVMExtraArgsV1 memory extraArgs) internal pure returns (bytes memory bts) {
        return abi.encodeWithSelector(EVM_EXTRA_ARGS_V1_TAG, extraArgs);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
