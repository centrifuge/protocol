// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

enum RestrictionUpdate {
    Invalid,
    UpdateMember,
    Freeze,
    Unfreeze
}

interface IRestrictionManager {
    // --- Events ---
    event UpdateMember(address indexed token, address indexed user, uint64 validUntil);
    event Freeze(address indexed token, address indexed user);
    event Unfreeze(address indexed token, address indexed user);

    // --- Handling freezes ---
    /// @notice Freeze a user balance. Frozen users cannot receive nor send tokens
    function freeze(address token, address user) external;

    /// @notice Unfreeze a user balance
    function unfreeze(address token, address user) external;

    /// @notice Returns whether the user's tokens are frozen
    function isFrozen(address token, address user) external view returns (bool);

    // --- Managing members ---
    /// @notice Add a member. Non-members cannot receive tokens, but can send tokens to valid members
    /// @param  validUntil Timestamp until which the user will be a valid member
    function updateMember(address token, address user, uint64 validUntil) external;

    /// @notice Returns whether the user is a valid member of the token
    function isMember(address token, address user) external view returns (bool isValid, uint64 validUntil);
}
