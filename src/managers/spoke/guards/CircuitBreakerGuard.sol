// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ICircuitBreakerGuard, CumulativeState, ReferenceState} from "./interfaces/ICircuitBreakerGuard.sol";

/// @title  CircuitBreakerGuard
/// @notice Rolling-window circuit breaker for weiroll scripts. Limits cumulative throughput
///         (e.g. bridge outflows) and per-update value deviation (e.g. price updates).
/// @dev    Called via weiroll CALL, so `msg.sender` is the Executor — state is per-executor.
contract CircuitBreakerGuard is ICircuitBreakerGuard {
    mapping(address caller => mapping(bytes32 key => ReferenceState)) public refs;
    mapping(address caller => mapping(bytes32 key => CumulativeState)) public cumulative;

    /// @inheritdoc ICircuitBreakerGuard
    function tally(bytes32 key, uint256 amount, uint256 max, uint256 window) external {
        CumulativeState storage s = cumulative[msg.sender][key];
        if (block.timestamp - s.windowStart > window) {
            s.windowStart = uint64(block.timestamp);
            s.total = amount.toUint128();
        } else {
            s.total += uint128(amount);
        }
        require(s.total <= max, ExceedsLimit());
    }

    /// @inheritdoc ICircuitBreakerGuard
    function delta(bytes32 key, uint256 currentValue, uint256 newValue, uint256 maxDeltaBps, uint256 window) external {
        ReferenceState storage s = refs[msg.sender][key];

        uint256 anchor;
        if (s.windowStart == 0 || block.timestamp - s.windowStart > window) {
            anchor = currentValue;
            s.anchor = uint128(currentValue);
            s.windowStart = uint64(block.timestamp);
        } else {
            anchor = s.anchor;
        }

        uint256 d = newValue > anchor ? newValue - anchor : anchor - newValue;
        require(d * 10_000 <= anchor * maxDeltaBps, ExceedsLimit());
    }
}
