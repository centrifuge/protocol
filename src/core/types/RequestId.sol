// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @dev Opaque identifier for a request within a (poolId, scId, assetId) tuple. Numeric so implementations can
///      pack structured ids (e.g. vault address and an incremental local id) and expose the ERC-7540/ERC-8161
///      `uint256 requestId` surface without conversion.
type RequestId is uint256;

function raw(RequestId requestId) pure returns (uint256) {
    return RequestId.unwrap(requestId);
}

using {raw} for RequestId global;
