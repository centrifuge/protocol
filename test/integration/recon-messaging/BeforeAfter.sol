// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Setup} from "./Setup.sol";

abstract contract BeforeAfter is Setup {
    // Ghost: cumulative delivery count per (centrifugeId, payloadHash)
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => uint256)) internal ghost_deliveries;

    // Ghost: ordered list of tracked (centrifugeId, payloadHash) pairs for property iteration
    uint16[] internal ghost_trackedCentrifugeIds;
    bytes32[] internal ghost_trackedPayloadHashes;
    mapping(uint16 centrifugeId => mapping(bytes32 payloadHash => bool)) internal ghost_isTracked;

    // Ghost: current adapter count (updated when setAdapters is called)
    uint8 internal ghost_adapterCount = ADAPTER_COUNT;

    function _recordDelivery(uint16 centrifugeId, bytes memory payload) internal {
        bytes32 payloadHash = keccak256(payload);
        ghost_deliveries[centrifugeId][payloadHash]++;

        if (!ghost_isTracked[centrifugeId][payloadHash]) {
            ghost_isTracked[centrifugeId][payloadHash] = true;
            ghost_trackedCentrifugeIds.push(centrifugeId);
            ghost_trackedPayloadHashes.push(payloadHash);
        }
    }
}
