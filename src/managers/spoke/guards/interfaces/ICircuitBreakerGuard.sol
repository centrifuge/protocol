// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

struct CumulativeState {
    uint128 total;
    uint64 windowStart;
}

struct ReferenceState {
    uint128 anchor;
    uint64 windowStart;
}

interface ICircuitBreakerGuard {
    error ExceedsLimit();

    /// @notice Tally an amount and revert if the rolling window limit is exceeded.
    ///         Use for bounding total throughput (e.g. bridge outflows per 24h).
    /// @param key     Identifier scoping this breaker (e.g. keccak256(abi.encode(poolId, asset))).
    /// @param amount  Amount to add to the tally.
    /// @param max     Maximum cumulative amount per window.
    /// @param window  Window duration in seconds.
    function tally(bytes32 key, uint256 amount, uint256 max, uint256 window) external;

    /// @notice Check that a new value doesn't deviate too far from a fixed anchor.
    ///         On the first call or when the window has expired, anchors to `currentValue`
    ///         (read from on-chain state via a prior weiroll command). Within the window,
    ///         all updates are compared to that fixed anchor.
    /// @param key           Identifier scoping this breaker.
    /// @param currentValue  Current on-chain value, used as anchor when starting a new window.
    /// @param newValue      The new value to validate against the anchor.
    /// @param maxDeltaBps   Maximum allowed deviation in basis points (e.g. 500 = 5%).
    /// @param window        Window duration in seconds.
    function delta(bytes32 key, uint256 currentValue, uint256 newValue, uint256 maxDeltaBps, uint256 window) external;

    function cumulative(address caller, bytes32 key) external view returns (uint128 total, uint64 windowStart);
    function refs(address caller, bytes32 key) external view returns (uint128 anchor, uint64 windowStart);
}
