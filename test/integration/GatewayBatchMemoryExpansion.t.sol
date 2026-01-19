// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CentrifugeIntegrationTest} from "./Integration.t.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {MessageLib} from "../../src/core/messaging/libraries/MessageLib.sol";
import {IUntrustedContractUpdate} from "../../src/core/utils/interfaces/IContractUpdate.sol";

import "forge-std/Test.sol";

/// @notice Simple mock that accepts UntrustedContractUpdate calls
contract MockUntrustedTarget is IUntrustedContractUpdate {
    function untrustedCall(PoolId, ShareClassId, bytes calldata, uint16, bytes32) external pure {}
}

/// @title Gateway Batch Memory Expansion Test
/// @notice Test to verify that max allowed batches from source chain can be processed on destination
contract GatewayBatchMemoryExpansionTest is CentrifugeIntegrationTest {
    using MessageLib for *;

    PoolId poolId;
    address target;

    function setUp() public override {
        super.setUp();
        poolId = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);

        // Deploy mock target that accepts UntrustedContractUpdate calls
        target = address(new MockUntrustedTarget());

        // Create a pool so messages are valid
        vm.prank(address(adminSafe));
        opsGuardian.createPool(poolId, address(this), USD_ID);

        // Give this test contract authorization to call gateway.handle()
        bytes32 slot = keccak256(abi.encode(address(this), uint256(0)));
        vm.store(address(gateway), slot, bytes32(uint256(1)));
    }

    /// @notice Creates an UntrustedContractUpdate message with 0 payload (107 bytes)
    function _createMessage() internal view returns (bytes memory) {
        return MessageLib.serialize(
            MessageLib.UntrustedContractUpdate({
                poolId: poolId.raw(),
                scId: "",
                target: bytes32(uint256(uint160(target))),
                sender: "",
                extraGasLimit: 0,
                payload: ""
            })
        );
    }

    /// @notice Creates a batch of n messages
    function _createBatch(uint256 n) internal view returns (bytes memory batch) {
        bytes memory msg_ = _createMessage();
        for (uint256 i = 0; i < n; i++) {
            batch = bytes.concat(batch, msg_);
        }
    }

    /// @notice Test that maximum allowed batch from source chain can be processed on destination
    function testMaxAllowedBatchCanBeProcessed() public {
        // Get gas limits from the system
        bytes memory singleMessage = _createMessage();
        uint128 perMessageGasLimit = gasService.messageOverallGasLimit(LOCAL_CENTRIFUGE_ID, singleMessage);

        // NOTE: if using 30_000_000 here, the safety margin is still 3.8 at the moment of this comment.
        // NOTE: limit is approx under a maxBatchLimit of 65_000_000
        uint128 maxBatchLimit = gasService.maxBatchGasLimit(LOCAL_CENTRIFUGE_ID);
        uint256 maxMessages = maxBatchLimit / perMessageGasLimit;

        bytes memory batch = _createBatch(maxMessages);

        console.log("=== Max Allowed Batch Test ===");
        console.log("Per-message gas limit:", perMessageGasLimit);
        console.log("Max batch gas limit:", maxBatchLimit);
        console.log("Max messages allowed:", maxMessages);
        console.log("Batch size:", batch.length, "bytes");
        console.log("");

        // Process the batch and measure gas
        uint256 gasBefore = gasleft();
        gateway.handle(LOCAL_CENTRIFUGE_ID, batch);
        uint256 gasConsumed = gasBefore - gasleft();

        console.log("Result:");
        console.log("  Gas consumed:", gasConsumed, "of", maxBatchLimit);
        console.log("  Safety margin: %s%", gasConsumed * 100 / maxBatchLimit);

        uint128 securityWard = 1_000_000;
        assertLe(gasConsumed, maxBatchLimit - securityWard, "Memory expansion error when processing the batch");
    }
}
