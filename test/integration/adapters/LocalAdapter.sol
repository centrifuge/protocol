// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../../../src/misc/Auth.sol";

import {IAdapter} from "../../../src/core/interfaces/IAdapter.sol";
import {IMessageHandler} from "../../../src/core/interfaces/IMessageHandler.sol";

import "forge-std/Test.sol";

import {MessageBenchmarker} from "../utils/MessageBenchmarker.sol";

/// An adapter that sends the message to another MessageHandler and acts as MessageHandler too.
contract LocalAdapter is Test, Auth, IAdapter, IMessageHandler {
    uint16 localCentrifugeId;
    IMessageHandler public entrypoint;
    IMessageHandler public endpoint;
    uint128 public refundedValue;

    bytes public lastReceivedPayload;
    MessageBenchmarker public benchmarker = new MessageBenchmarker();

    constructor(uint16 localCentrifugeId_, IMessageHandler entrypoint_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        localCentrifugeId = localCentrifugeId_;
    }

    function setEndpoint(IMessageHandler endpoint_) public {
        endpoint = endpoint_;
        benchmarker.setHandler(endpoint);
    }

    function setRefundedValue(uint128 refundedValue_) public {
        refundedValue = refundedValue_;
    }

    /// @inheritdoc IMessageHandler
    function handle(uint16 remoteCentrifugeId, bytes calldata message) external {
        // Local messages must be bypassed
        assertNotEq(localCentrifugeId, remoteCentrifugeId, "Local messages must be bypassed");

        entrypoint.handle(remoteCentrifugeId, message);
    }

    /// @inheritdoc IAdapter
    function send(uint16 remoteCentrifugeId, bytes calldata payload, uint256, address refund)
        external
        payable
        returns (bytes32 adapterData)
    {
        // Local messages must be bypassed
        assertNotEq(remoteCentrifugeId, localCentrifugeId, "Local messages must be bypassed");

        // Only run the benchmarks if using one thread to avoid concurrence issues writing the json
        // Example of command: RAYON_NUM_THREADS=1 BENCHMARKING_RUN_ID="$(date +%s)" forge test EndToEnd
        if (vm.envOr("RAYON_NUM_THREADS", uint256(0)) == 1) {
            benchmarker.handle(localCentrifugeId, payload);
        } else {
            // The other handler will receive the message as coming from this
            endpoint.handle(localCentrifugeId, payload);
        }

        adapterData = bytes32("");
        lastReceivedPayload = payload;

        (bool success,) = payable(refund).call{value: refundedValue}(new bytes(0));
        assertEq(success, true, "Refund must success");
    }

    /// @inheritdoc IAdapter
    function estimate(uint16, bytes calldata, uint256 gasLimit) public pure returns (uint256 nativePriceQuote) {
        return gasLimit;
    }
}
