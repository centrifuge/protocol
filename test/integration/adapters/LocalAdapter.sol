// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

/// An adapter that sends the message to the another MessageHandler and acts as MessageHandler too.
contract LocalAdapter is Test, Auth, IAdapter, IMessageHandler {
    uint16 sourceChainId;
    IMessageHandler public gateway;
    IMessageHandler public endpoint;

    constructor(uint16 chainId_, IMessageHandler gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
        sourceChainId = chainId_;
    }

    function setEndpoint(IMessageHandler endpoint_) public {
        endpoint = endpoint_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 chainId, bytes calldata message) external {
        // Local messages must be bypassed
        assertEq(sourceChainId, chainId, "Expected same chain");

        gateway.handle(chainId, message);
    }

    /// @inheritdoc IAdapter
    function send(uint16 destinationChainId, bytes calldata payload, uint256, address) external payable {
        // Local messages must be bypassed
        assertNotEq(destinationChainId, sourceChainId, "Local messages must by bypassed");
        endpoint.handle(destinationChainId, payload);
    }

    /// @inheritdoc IAdapter
    function estimate(uint16, bytes calldata, uint256 gasLimit) public pure returns (uint256 nativePriceQuote) {
        return gasLimit;
    }
}
