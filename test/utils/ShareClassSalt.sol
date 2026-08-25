// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.8.0;

/// @dev Builds a share class salt the way the protocol requires: its first 8 bytes are the pool id, so
///      pools cannot collide inside a shared registrar's CREATE2 namespace. `ShareClassManager` enforces
///      this on the hub and `SpokeHandler` re-checks it on the spoke, so tests reaching the spoke directly
///      (bypassing the hub) must build their salts here rather than hashing freely.
function shareClassSalt(uint64 poolId, bytes16 scId) pure returns (bytes32) {
    return bytes32((uint256(poolId) << 192) | (uint256(keccak256(abi.encodePacked(poolId, scId))) >> 64));
}
