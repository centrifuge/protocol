// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";

import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {ShareClassId} from "../../src/core/types/ShareClassId.sol";

/// @dev Minimal token that satisfies the registry's `code.length > 0` check on the deployed share token.
contract PayloadToken {}

/// @dev Registrar that records the creation payload the spoke forwards to `newToken`.
contract PayloadRecordingRegistrar {
    bytes public lastPayload;

    function newToken(string memory, string memory, uint8, bytes32, bytes memory payload) external returns (address) {
        lastPayload = payload;
        return address(new PayloadToken());
    }
}

/// @dev Validates that the share-class creation payload survives the full hub -> spoke message round-trip,
///      exercising the 2-byte big-endian length prefix and the `slice(268, n)` payload boundary in
///      `deserializeNotifyShareClass`.
contract ShareClassPayloadTest is EndToEndFlows {
    using CastLib for *;

    /// @dev The share-class salt must carry the pool id in its leading 8 bytes (see `ShareClassManager.InvalidSalt`).
    function _salt(bytes24 tag) internal view returns (bytes32) {
        return bytes32(abi.encodePacked(bytes8(POOL_A.raw()), tag));
    }

    function testNotifyShareClassForwardsLargePayloadCrossChain() public {
        _configurePool(false);

        PayloadRecordingRegistrar registrar = new PayloadRecordingRegistrar();

        // >256 bytes forces a multi-byte length prefix on the wire, so a truncated read would corrupt it.
        bytes memory payload = new bytes(300);
        for (uint256 i; i < payload.length; i++) {
            payload[i] = bytes1(uint8(i));
        }

        vm.startPrank(FM);
        ShareClassId scId = h.hub.addShareClass(POOL_A, "Second Class", "SC2", _salt("second"));
        h.hub.notifyShareClass{value: GAS}(
            POOL_A, scId, s.centrifugeId, address(registrar).toBytes32(), payload, EXTRA_GAS, REFUND
        );
        vm.stopPrank();

        assertEq(registrar.lastPayload(), payload, "payload corrupted across the message round-trip");
    }

    function testNotifyShareClassForwardsEmptyPayload() public {
        _configurePool(false);

        PayloadRecordingRegistrar registrar = new PayloadRecordingRegistrar();

        vm.startPrank(FM);
        ShareClassId scId = h.hub.addShareClass(POOL_A, "Third Class", "SC3", _salt("third"));
        h.hub.notifyShareClass{value: GAS}(
            POOL_A, scId, s.centrifugeId, address(registrar).toBytes32(), "", EXTRA_GAS, REFUND
        );
        vm.stopPrank();

        assertEq(registrar.lastPayload().length, 0, "empty payload must arrive empty");
    }
}
