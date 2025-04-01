// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";

/// An adapter that sends the message to the another MessageHandler and acts as MessageHandler too.
contract LocalAdapter is Test, Auth, IAdapter, IMessageHandler {
    uint16 localId;
    IMessageHandler public gateway;
    IMessageHandler public endpoint;

    constructor(uint16 localId_, IMessageHandler gateway_, address deployer) Auth(deployer) {
        gateway = gateway_;
        localId = localId_;
    }

    function setEndpoint(IMessageHandler endpoint_) public {
        endpoint = endpoint_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 remoteId, bytes calldata message) external {
        // Local messages must be bypassed
        assertNotEq(localId, remoteId, "Local messages must be bypassed");

        gateway.handle(remoteId, message);
    }

    /// @inheritdoc IAdapter
    function send(uint16 destinationId, bytes calldata payload, uint256, address) external payable {
        // Local messages must be bypassed
        assertNotEq(destinationId, localId, "Local messages must be bypassed");

        // The other handler will receive the message as comming from this
        endpoint.handle(localId, payload);
    }

    /// @inheritdoc IAdapter
    function estimate(uint16, bytes calldata, uint256 gasLimit) public pure returns (uint256 nativePriceQuote) {
        return gasLimit;
    }
}
