// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IFreezable {
    // --- Events ---
    event Freeze(address indexed token, address indexed user);
    event Unfreeze(address indexed token, address indexed user);

    // --- Errors ---
    error CannotFreezeZeroAddress();
    error EndorsedUserCannotBeFrozen();

    // --- Handling freezes ---
    /// @notice Freeze a user balance. Frozen users cannot receive nor send tokens
    function freeze(address token, address user) external;

    /// @notice Unfreeze a user balance
    function unfreeze(address token, address user) external;

    /// @notice Returns whether the user's tokens are frozen
    function isFrozen(address token, address user) external view returns (bool);
}
