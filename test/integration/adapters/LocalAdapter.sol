// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";

import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

/// An adapter that sends the message to another MessageHandler and acts as MessageHandler too.
contract LocalAdapter is Test, Auth, IAdapter, IMessageHandler {
    uint16 localCentrifugeId;
    IMessageHandler public entrypoint;
    IMessageHandler public endpoint;

    constructor(uint16 localCentrifugeId_, IMessageHandler entrypoint_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        localCentrifugeId = localCentrifugeId_;
    }

    function setEndpoint(IMessageHandler endpoint_) public {
        endpoint = endpoint_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 remoteCentrifugeId, bytes calldata message) external {
        // Local messages must be bypassed
        assertNotEq(localCentrifugeId, remoteCentrifugeId, "Local messages must be bypassed");

        entrypoint.handle(remoteCentrifugeId, message);
    }

    /// @inheritdoc IAdapter
    function send(uint16 remoteCentrifugeId, bytes calldata payload, uint256, address)
        external
        payable
        returns (bytes32 adapterData)
    {
        // Local messages must be bypassed
        assertNotEq(remoteCentrifugeId, localCentrifugeId, "Local messages must be bypassed");

        // The other handler will receive the message as coming from this
        endpoint.handle(localCentrifugeId, payload);

        adapterData = bytes32("");
    }

    /// @inheritdoc IAdapter
    function estimate(uint16, bytes calldata, uint256 gasLimit) public pure returns (uint256 nativePriceQuote) {
        return gasLimit;
    }
}
