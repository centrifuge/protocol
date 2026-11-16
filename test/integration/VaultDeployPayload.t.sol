// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";

/// @dev Minimal vault that satisfies the register/link checks.
contract PayloadVault {
    PoolId public immutable poolId;
    ShareClassId public immutable scId;

    constructor(PoolId poolId_, ShareClassId scId_) {
        poolId = poolId_;
        scId = scId_;
    }
}

/// @dev Factory that emits the deployment payload the spoke forwards to `newVault`, and returns a vault
///      deployed ahead of the message, as `VaultFactory` does. An event rather than storage, which a payload this
///      size would not fit into the priced gas of a register and link.
contract PayloadRecordingFactory {
    event Payload(bytes payload);

    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function newVault(PoolId, ShareClassId, address, uint256, address, bytes calldata payload)
        external
        returns (address)
    {
        emit Payload(payload);
        return vault;
    }
}

/// @dev Validates that the vault-deploy payload survives the full hub -> spoke message round-trip, exercising the
///      2-byte big-endian length prefix and the `slice(92, n)` payload boundary in `deserializeUpdateVault`.
contract VaultDeployPayloadTest is EndToEndFlows {
    function testDeployVaultForwardsLargePayloadCrossChain() public {
        _configurePool(false);

        PayloadRecordingFactory factory = new PayloadRecordingFactory(address(new PayloadVault(POOL_A, SC_1)));

        // >256 bytes forces a multi-byte length prefix on the wire, so a truncated read would corrupt it.
        bytes memory payload = new bytes(300);
        for (uint256 i; i < payload.length; i++) {
            payload[i] = bytes1(uint8(i));
        }

        vm.expectEmit(address(factory));
        emit PayloadRecordingFactory.Payload(payload);
        vm.prank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A,
            SC_1,
            s.usdcId,
            bytes32(bytes20(address(factory))),
            VaultUpdateKind.DeployAndLink,
            payload,
            EXTRA_GAS,
            REFUND
        );
    }
}
