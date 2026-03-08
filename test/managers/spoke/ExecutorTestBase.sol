// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";

import {IExecutor} from "../../../src/managers/spoke/interfaces/IExecutor.sol";

import "forge-std/Test.sol";

// ─── Mock target for weiroll commands ─────────────────────────────────────────

contract WeirollTarget {
    uint256 public lastValue;

    function setValue(uint256 v) external {
        lastValue = v;
    }

    function getValue() external view returns (uint256) {
        return lastValue;
    }

    function add(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }

    function setValuePayable(uint256 v) external payable {
        lastValue = v;
    }

    function alwaysReverts() external pure {
        revert("target reverted");
    }

    receive() external payable {}
}

// ─── Shared base with weiroll command builders and policy helpers ─────────────

abstract contract ExecutorTestBase is Test {
    using CastLib for *;

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    // Weiroll call type flags (byte 4 of command)
    uint256 constant FLAG_CT_CALL = 0x01;
    uint256 constant FLAG_CT_STATICCALL = 0x02;
    uint256 constant FLAG_CT_VALUECALL = 0x03;

    // ─── Command builder helpers ──────────────────────────────────────────

    /// @dev Build a weiroll command bytes32.
    ///      Layout: [0..3] selector, [4] flags, [5..10] indices, [11] output, [12..31] target(20 bytes)
    function _buildCommand(bytes4 selector, uint8 flags, bytes6 indices, uint8 output, address target_)
        internal
        pure
        returns (bytes32)
    {
        return bytes32(
            (uint256(uint32(selector)) << 224) | (uint256(flags) << 216) | (uint256(uint48(indices)) << 168)
                | (uint256(output) << 160) | uint256(uint160(target_))
        );
    }

    /// @dev Short-hand for a CALL command with one fixed uint256 input from state[inputIdx],
    ///      no output (0xff = discard).
    function _callCommand(bytes4 selector, uint8 inputIdx, address target_) internal pure returns (bytes32) {
        bytes6 indices = bytes6(uint48(uint256(inputIdx) << 40 | 0xFFFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_CALL), indices, 0xff, target_);
    }

    /// @dev STATICCALL with no inputs, output stored at state[outputIdx].
    function _staticCallNoInputs(bytes4 selector, uint8 outputIdx, address target_) internal pure returns (bytes32) {
        bytes6 indices = bytes6(uint48(0xFFFFFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_STATICCALL), indices, outputIdx, target_);
    }

    /// @dev CALL with two inputs from state[idx0] and state[idx1], no output.
    function _callCommand2(bytes4 selector, uint8 idx0, uint8 idx1, address target_) internal pure returns (bytes32) {
        bytes6 indices = bytes6(uint48(uint256(idx0) << 40 | uint256(idx1) << 32 | 0xFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_CALL), indices, 0xff, target_);
    }

    /// @dev STATICCALL with two inputs, output to state[outputIdx].
    function _staticCall2(bytes4 selector, uint8 idx0, uint8 idx1, uint8 outputIdx, address target_)
        internal
        pure
        returns (bytes32)
    {
        bytes6 indices = bytes6(uint48(uint256(idx0) << 40 | uint256(idx1) << 32 | 0xFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_STATICCALL), indices, outputIdx, target_);
    }

    /// @dev VALUECALL: first index is ETH value from state, second is the function arg.
    function _valueCallCommand(bytes4 selector, uint8 valueIdx, uint8 inputIdx, address target_)
        internal
        pure
        returns (bytes32)
    {
        bytes6 indices = bytes6(uint48(uint256(valueIdx) << 40 | uint256(inputIdx) << 32 | 0xFFFFFFFF));
        return _buildCommand(selector, uint8(FLAG_CT_VALUECALL), indices, 0xff, target_);
    }

    // ─── Policy/hash helpers ─────────────────────────────────────────────

    function _setPolicy(IExecutor executor, address who, bytes32 root, address contractUpdater) internal {
        bytes memory payload = abi.encode(who.toBytes32(), root);
        vm.prank(contractUpdater);
        executor.trustedCall(POOL_A, SC_1, payload);
    }

    function _computeScriptHash(
        bytes32[] memory commands,
        bytes[] memory state,
        uint256 stateBitmap,
        bytes32 callbackHash
    ) internal pure returns (bytes32) {
        return keccak256(
            abi.encodePacked(
                keccak256(abi.encodePacked(commands)),
                _hashFixedState(state, stateBitmap),
                stateBitmap,
                state.length,
                callbackHash
            )
        );
    }

    function _hashFixedState(bytes[] memory state, uint256 stateBitmap) internal pure returns (bytes32) {
        bytes memory packed;
        for (uint256 i; i < state.length; i++) {
            if (stateBitmap & (1 << i) != 0) {
                packed = bytes.concat(packed, keccak256(state[i]));
            }
        }
        return keccak256(packed);
    }

    function _merkleRoot2(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
}
