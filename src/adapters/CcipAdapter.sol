// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICCIPAdapter, IAdapter, CCIPSource, CCIPDestination} from "./interfaces/ICCIPAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

import {IMessageHandler} from "../common/interfaces/IMessageHandler.sol";
import {IRouterClient} from "@chainlink-ccip/interfaces/IRouterClient.sol";
import {Client} from "@chainlink-ccip/libraries/Client.sol";

/// @title  CCIP Adapter
/// @notice Routing contract that integrates with Chainlink CCIP
contract CCIPAdapter is Auth, ICCIPAdapter {
    using CastLib for *;

    IMessageHandler public immutable entrypoint;
    IRouterClient public immutable ccipRouter;

    mapping(uint64 chainSelector => CCIPSource) public sources;
    mapping(uint16 centrifugeId => CCIPDestination) public destinations;

    error InvalidRouter();
    error InvalidSourceChain();
    error InvalidSourceAddress();
    error InsufficientFeeTokenAmount();
    error RefundFailed();

    constructor(IMessageHandler entrypoint_, address ccipRouter_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        ccipRouter = IRouterClient(ccipRouter_);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ICCIPAdapter
    function wire(uint16 centrifugeId, uint64 chainSelector, address adapter) external auth {
        sources[chainSelector] = CCIPSource(centrifugeId, keccak256(abi.encodePacked(adapter)));
        destinations[centrifugeId] = CCIPDestination(chainSelector, adapter);
        emit Wire(centrifugeId, chainSelector, adapter);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ICCIPAdapter
    function ccipReceive(Client.Any2EVMMessage calldata message) external {
        require(msg.sender == address(ccipRouter), InvalidRouter());

        CCIPSource memory source = sources[message.sourceChainSelector];
        require(source.addressHash != bytes32(""), InvalidSourceChain());

        address sourceAddress = abi.decode(message.sender, (address));
        require(source.addressHash == keccak256(abi.encodePacked(sourceAddress)), InvalidSourceAddress());

        entrypoint.handle(source.centrifugeId, message.data);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit, address refund)
    external
    payable
    returns (bytes32 adapterData)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        CCIPDestination memory destination = destinations[centrifugeId];
        require(destination.chainSelector != 0, UnknownChainId());

        // Build CCIP message
        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destination.adapter),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0), // Pay in native token
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit}))
        });

        // Get exact fee amount needed
        uint256 fee = ccipRouter.getFee(destination.chainSelector, ccipMessage);
        require(msg.value >= fee, InsufficientFeeTokenAmount());

        // Send message with exact fee
        bytes32 messageId = ccipRouter.ccipSend{value: fee}(destination.chainSelector, ccipMessage);

        // Refund entire contract ETH balance to the specified recipient
        uint256 leftover = address(this).balance;
        if (leftover > 0 && refund != address(0)) {
            (bool success,) = refund.call{value: leftover}("");
            require(success, RefundFailed());
            emit LeftoverRefund(refund, leftover);
        }

        adapterData = messageId;
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        CCIPDestination memory destination = destinations[centrifugeId];
        require(destination.chainSelector != 0, UnknownChainId());

        Client.EVM2AnyMessage memory ccipMessage = Client.EVM2AnyMessage({
            receiver: abi.encode(destination.adapter),
            data: payload,
            tokenAmounts: new Client.EVMTokenAmount[](0),
            feeToken: address(0),
            extraArgs: Client._argsToBytes(Client.EVMExtraArgsV1({gasLimit: gasLimit}))
        });

        return ccipRouter.getFee(destination.chainSelector, ccipMessage);
    }

    /// @notice Allow contract to receive ETH
    receive() external payable {}
}
