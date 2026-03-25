// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface ICircuitBreakerGuard {
    error ExceedsLimit();

    /// @notice Tally an amount and revert if the rolling window limit is exceeded.
    ///         Use for bounding total throughput (e.g. bridge outflows per 24h).
    /// @param key     Identifier scoping this breaker (e.g. keccak256(abi.encode(poolId, asset))).
    /// @param amount  Amount to add to the tally.
    /// @param max     Maximum cumulative amount per window.
    /// @param window  Window duration in seconds.
    function tally(bytes32 key, uint256 amount, uint256 max, uint256 window) external;

    /// @notice Check that a new value doesn't deviate too far from the cached reference.
    ///         If no reference exists or it is older than `window`, accepts any value.
    ///         Use for bounding per-update deviation (e.g. share price updates).
    /// @param key          Identifier scoping this breaker.
    /// @param newValue     The new value to validate.
    /// @param maxDeltaBps  Maximum allowed deviation in basis points (e.g. 500 = 5%).
    /// @param window       Staleness window in seconds; references older than this are ignored.
    function delta(bytes32 key, uint256 newValue, uint256 maxDeltaBps, uint256 window) external;

    function cumulative(address caller, bytes32 key) external view returns (uint128 total, uint64 windowStart);
    function refs(address caller, bytes32 key) external view returns (uint128 value, uint64 lastUpdate);
}
