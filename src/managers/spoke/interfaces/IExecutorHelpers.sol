// SPDX-License-Identifier: GPL-3.0-only
pragma solidity 0.8.28;

import {MathLib} from "../../../misc/libraries/MathLib.sol";

/// @title  IExecutorHelpers
/// @notice Interface for weiroll script utility functions.
interface IExecutorHelpers {
    // ──────────────────────────────────────────────────────────────────────
    // Errors
    // ──────────────────────────────────────────────────────────────────────

    error ConditionFalse();
    error ConditionTrue();
    error CastOverflow();

    // ──────────────────────────────────────────────────────────────────────
    // Guards
    // ──────────────────────────────────────────────────────────────────────

    function revertIfFalse(bool condition) external pure;
    function revertIfTrue(bool condition) external pure;

    // ──────────────────────────────────────────────────────────────────────
    // Arithmetic
    // ──────────────────────────────────────────────────────────────────────

    function add(uint256 a, uint256 b) external pure returns (uint256);
    function sub(uint256 a, uint256 b) external pure returns (uint256);
    function subSaturating(uint256 a, uint256 b) external pure returns (uint256);
    function mul(uint256 a, uint256 b) external pure returns (uint256);
    function div(uint256 a, uint256 b) external pure returns (uint256);
    function mulDiv(uint256 a, uint256 b, uint256 c, MathLib.Rounding rounding) external pure returns (uint256);
    function subBps(uint256 amount, uint256 bps) external pure returns (uint256);
    function addBps(uint256 amount, uint256 bps) external pure returns (uint256);
    function scaleDecimals(uint256 amount, uint8 fromDecimals, uint8 toDecimals) external pure returns (uint256);

    // ──────────────────────────────────────────────────────────────────────
    // Comparisons
    // ──────────────────────────────────────────────────────────────────────

    function eq(uint256 a, uint256 b) external pure returns (bool);
    function gt(uint256 a, uint256 b) external pure returns (bool);
    function lt(uint256 a, uint256 b) external pure returns (bool);
    function gte(uint256 a, uint256 b) external pure returns (bool);
    function lte(uint256 a, uint256 b) external pure returns (bool);
    function max(uint256 a, uint256 b) external pure returns (uint256);
    function min(uint256 a, uint256 b) external pure returns (uint256);
    function clamp(uint256 value, uint256 low, uint256 high) external pure returns (uint256);

    // ──────────────────────────────────────────────────────────────────────
    // Boolean logic
    // ──────────────────────────────────────────────────────────────────────

    function not(bool x) external pure returns (bool);
    function and(bool x, bool y) external pure returns (bool);
    function or(bool x, bool y) external pure returns (bool);

    // ──────────────────────────────────────────────────────────────────────
    // Branching
    // ──────────────────────────────────────────────────────────────────────

    function ternary(bool condition, uint256 a, uint256 b) external pure returns (uint256);
    function ternary(bool condition, bytes32 a, bytes32 b) external pure returns (bytes32);

    // ──────────────────────────────────────────────────────────────────────
    // Context
    // ──────────────────────────────────────────────────────────────────────

    function blockTimestamp() external view returns (uint256);
    function blockTimestampOffset(uint256 offset) external view returns (uint256);

    // ──────────────────────────────────────────────────────────────────────
    // ABI decoding
    // ──────────────────────────────────────────────────────────────────────

    function extractElement(bytes memory tuple, uint256 index) external pure returns (bytes32);

    // ──────────────────────────────────────────────────────────────────────
    // Type casting
    // ──────────────────────────────────────────────────────────────────────

    function toUint256(int256 value) external pure returns (uint256);
    function toInt256(uint256 value) external pure returns (int256);
    function abs(int256 value) external pure returns (uint256);
    function toAddress(bytes32 value) external pure returns (address);
    function toBytes32(address value) external pure returns (bytes32);
    function toUint256(bytes32 value) external pure returns (uint256);
    function toBytes32(uint256 value) external pure returns (bytes32);
}
