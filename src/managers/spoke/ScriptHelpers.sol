// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IScriptHelpers} from "./interfaces/IScriptHelpers.sol";

import {MathLib} from "../../misc/libraries/MathLib.sol";

/// @title  Script Helpers
/// @notice Stateless utility functions for use as weiroll script targets.
/// @dev    Since weiroll uses CALL (not DELEGATECALL), these run in the helper's context
///         and cannot touch the OnchainPM's storage.
contract ScriptHelpers is IScriptHelpers {
    using MathLib for uint256;

    uint256 internal constant BPS_BASE = 10_000;

    //----------------------------------------------------------------------------------------------
    // Guards
    //----------------------------------------------------------------------------------------------

    /// @notice Reverts if the condition is false. Weiroll equivalent of `require(condition)`.
    function revertIfFalse(bool condition) external pure {
        require(condition, ConditionFalse());
    }

    /// @notice Reverts if the condition is true.
    function revertIfTrue(bool condition) external pure {
        require(!condition, ConditionTrue());
    }

    //----------------------------------------------------------------------------------------------
    // Arithmetic
    //----------------------------------------------------------------------------------------------

    function add(uint256 a, uint256 b) external pure returns (uint256) {
        return a + b;
    }

    function sub(uint256 a, uint256 b) external pure returns (uint256) {
        return a - b;
    }

    /// @notice Returns a - b, or 0 if b > a. Prevents reverts on rounding dust.
    function subSaturating(uint256 a, uint256 b) external pure returns (uint256) {
        return a >= b ? a - b : 0;
    }

    function mul(uint256 a, uint256 b) external pure returns (uint256) {
        return a * b;
    }

    function div(uint256 a, uint256 b) external pure returns (uint256) {
        return a / b;
    }

    /// @notice Returns (a * b / c) with full-precision intermediate result and configurable rounding.
    /// @param  rounding 0 = Down (floor), 1 = Up (ceil), 2 = Zero (toward zero).
    function mulDiv(uint256 a, uint256 b, uint256 c, MathLib.Rounding rounding) external pure returns (uint256) {
        return a.mulDiv(b, c, rounding);
    }

    /// @notice Returns amount * (10_000 - bps) / 10_000. One-call slippage application.
    function subBps(uint256 amount, uint256 bps) external pure returns (uint256) {
        require(bps <= BPS_BASE, InvalidBps());
        return amount * (BPS_BASE - bps) / BPS_BASE;
    }

    /// @notice Returns amount * (10_000 + bps) / 10_000. Upper bound calculation.
    function addBps(uint256 amount, uint256 bps) external pure returns (uint256) {
        return amount * (BPS_BASE + bps) / BPS_BASE;
    }

    /// @notice Converts an amount between token decimal representations.
    /// @param  rounding 0 = Down (floor), 1 = Up (ceil). Only applies when reducing decimals.
    function scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals, MathLib.Rounding rounding)
        external
        pure
        returns (uint256)
    {
        if (fromDecimals == toDecimals) return amount;
        if (fromDecimals < toDecimals) return amount * 10 ** (toDecimals - fromDecimals);
        uint256 divisor = 10 ** (fromDecimals - toDecimals);
        uint256 result = amount / divisor;
        if (rounding == MathLib.Rounding.Up && amount % divisor != 0) result++;
        return result;
    }

    //----------------------------------------------------------------------------------------------
    // Comparisons
    //----------------------------------------------------------------------------------------------

    function eq(uint256 a, uint256 b) external pure returns (bool) {
        return a == b;
    }

    function gt(uint256 a, uint256 b) external pure returns (bool) {
        return a > b;
    }

    function lt(uint256 a, uint256 b) external pure returns (bool) {
        return a < b;
    }

    function gte(uint256 a, uint256 b) external pure returns (bool) {
        return a >= b;
    }

    function lte(uint256 a, uint256 b) external pure returns (bool) {
        return a <= b;
    }

    function max(uint256 a, uint256 b) external pure returns (uint256) {
        return MathLib.max(a, b);
    }

    function min(uint256 a, uint256 b) external pure returns (uint256) {
        return MathLib.min(a, b);
    }

    /// @notice Returns max(low, min(value, high)).
    function clamp(uint256 value, uint256 low, uint256 high) external pure returns (uint256) {
        return MathLib.max(low, MathLib.min(value, high));
    }

    //----------------------------------------------------------------------------------------------
    // Boolean logic
    //----------------------------------------------------------------------------------------------

    function not(bool x) external pure returns (bool) {
        return !x;
    }

    function and(bool x, bool y) external pure returns (bool) {
        return x && y;
    }

    function or(bool x, bool y) external pure returns (bool) {
        return x || y;
    }

    //----------------------------------------------------------------------------------------------
    // Branching
    //----------------------------------------------------------------------------------------------

    /// @notice Returns `a` if `condition` is true, `b` otherwise.
    function ternary(bool condition, uint256 a, uint256 b) external pure returns (uint256) {
        return condition ? a : b;
    }

    /// @notice Bytes32 variant for address/bytes32 branching.
    function ternary(bool condition, bytes32 a, bytes32 b) external pure returns (bytes32) {
        return condition ? a : b;
    }

    //----------------------------------------------------------------------------------------------
    // Context
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the current block timestamp.
    function blockTimestamp() external view returns (uint256) {
        return block.timestamp;
    }

    /// @notice Returns block.timestamp + offset. Useful for swap deadlines.
    function blockTimestampOffset(uint256 offset) external view returns (uint256) {
        return block.timestamp + offset;
    }

    //----------------------------------------------------------------------------------------------
    // ABI decoding
    //----------------------------------------------------------------------------------------------

    /// @notice Extract a 32-byte word at `index` from a raw ABI-encoded tuple.
    /// @dev    Useful for destructuring multi-return values captured via FLAG_TUPLE_RETURN.
    ///         Index 0 returns the first 32-byte word, index 1 the second, etc.
    function extractElement(bytes memory tuple, uint256 index) external pure returns (bytes32 result) {
        uint256 offset = index * 32;
        require(tuple.length >= offset + 32, OutOfBounds());
        assembly {
            result := mload(add(add(tuple, 32), offset))
        }
    }

    //----------------------------------------------------------------------------------------------
    // Type casting
    //----------------------------------------------------------------------------------------------

    function toUint256(int256 value) external pure returns (uint256) {
        require(value >= 0, CastOverflow());
        return uint256(value);
    }

    function toInt256(uint256 value) external pure returns (int256) {
        require(value <= uint256(type(int256).max), CastOverflow());
        return int256(value);
    }

    function abs(int256 value) external pure returns (uint256) {
        return value >= 0 ? uint256(value) : uint256(-value);
    }

    function toAddress(bytes32 value) external pure returns (address) {
        return address(uint160(uint256(value)));
    }

    function toBytes32(address value) external pure returns (bytes32) {
        return bytes32(uint256(uint160(value)));
    }

    function toUint256(bytes32 value) external pure returns (uint256) {
        return uint256(value);
    }

    function toBytes32(uint256 value) external pure returns (bytes32) {
        return bytes32(value);
    }

    //----------------------------------------------------------------------------------------------
    // ABI encoding
    //----------------------------------------------------------------------------------------------

    /// @notice ABI-encode a single uint128 as 32 bytes (left-padded).
    function encodeUint128(uint128 value) external pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice ABI-encode a single uint256 as 32 bytes.
    function encodeUint256(uint256 value) external pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice ABI-encode a single address as 32 bytes (left-padded).
    function encodeAddress(address value) external pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice ABI-encode a single bytes32.
    function encodeBytes32(bytes32 value) external pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice ABI-encode a single bool as 32 bytes.
    function encodeBool(bool value) external pure returns (bytes memory) {
        return abi.encode(value);
    }

    /// @notice Concatenate two byte arrays.
    function bytesConcat(bytes memory a, bytes memory b) external pure returns (bytes memory) {
        return bytes.concat(a, b);
    }
}
