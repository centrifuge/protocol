// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

interface IPoolLocker {
    /// @notice Dispatched when the pool is already unlocked.
    /// It means when calling to `execute()` inside `execute()`.
    error PoolAlreadyUnlocked();

    /// @notice Dispatched when the `targets` and `datas` length parameters in `execute()` do not matched.
    error WrongExecutionParams();

    /// @notice Returns the unlocked poolId.
    /// In only will contain a non-zero value if called inside `execute()`
    function unlockedPoolId() external returns (uint64);

    /// @notice Execute a multicall inside an unlocked pool.
    /// In one call fails, it reverts the whole transaction.
    function execute(uint64 poolId, address[] calldata targets, bytes[] calldata datas)
        external
        returns (bytes[] memory results);
}
