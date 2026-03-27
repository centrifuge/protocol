// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICircuitBreakerGuard, CumulativeState, ReferenceState} from "./interfaces/ICircuitBreakerGuard.sol";

import {MathLib} from "../../../misc/libraries/MathLib.sol";

/// @title  CircuitBreakerGuard
/// @notice Rolling-window circuit breaker for weiroll scripts. Limits cumulative throughput
///         (e.g. bridge outflows) and per-update value deviation (e.g. price updates).
/// @dev    Called via weiroll CALL, so `msg.sender` is the Executor — state is per-executor.
contract CircuitBreakerGuard is ICircuitBreakerGuard {
    using MathLib for uint256;

    mapping(address caller => mapping(bytes32 key => mapping(uint256 window => ReferenceState))) public refs;
    mapping(address caller => mapping(bytes32 key => mapping(uint256 window => CumulativeState))) public cumulative;

    /// @inheritdoc ICircuitBreakerGuard
    function tally(bytes32 key, uint256 amount, uint256 max, uint256 window) external {
        CumulativeState storage s = cumulative[msg.sender][key][window];
        uint256 newTotal;
        if (block.timestamp - s.windowStart > window) {
            s.windowStart = uint64(block.timestamp);
            newTotal = amount;
        } else {
            newTotal = uint256(s.total) + amount;
        }
        require(newTotal <= max, ExceedsCumulativeLimit(key, amount, max, window));
        s.total = newTotal.toUint128();
    }

    /// @inheritdoc ICircuitBreakerGuard
    function delta(bytes32 key, uint256 currentValue, uint256 newValue, uint256 maxDeltaBps, uint256 window) external {
        if (currentValue == 0) return;

        uint256 anchor;
        ReferenceState storage s = refs[msg.sender][key][window];
        if (s.windowStart == 0 || block.timestamp - s.windowStart > window) {
            anchor = currentValue;
            s.anchor = uint128(currentValue);
            s.windowStart = uint64(block.timestamp);
        } else {
            anchor = s.anchor;
        }

        uint256 d = newValue > anchor ? newValue - anchor : anchor - newValue;
        require(d * 10_000 <= anchor * maxDeltaBps, ExceedsDeltaLimit(key, currentValue, newValue, maxDeltaBps, window));
    }
}
