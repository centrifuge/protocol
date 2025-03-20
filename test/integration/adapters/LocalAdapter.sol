// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

/// An adapter that sends the message to the another MessageHandler and acts as MessageHandler too.
contract LocalAdapter is Auth, IAdapter, IMessageHandler {
    IMessageHandler public gateway;
    IMessageHandler public endpoint;

    constructor(IMessageHandler gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
    }

    function setEndpoint(IMessageHandler endpoint_) public {
        endpoint = endpoint_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint32 chainId, bytes calldata message) external {
        gateway.handle(chainId, message);
    }

    /// @inheritdoc IAdapter
    function send(uint32 destinationChainId, bytes calldata payload, uint256, address) external payable {
        endpoint.handle(destinationChainId, payload);
    }

    /// @inheritdoc IAdapter
    function estimate(uint32, bytes calldata, uint256 gasLimit) public pure returns (uint256 nativePriceQuote) {
        return gasLimit;
    }
}
