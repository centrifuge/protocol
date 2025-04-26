// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IMemberlist {
    // --- Events ---
    event UpdateMember(address indexed token, address indexed user, uint64 validUntil);

    // --- Errors ---
    error InvalidValidUntil();
    error EndorsedUserCannotBeUpdated();

    // --- Managing members ---
    /// @notice Add a member. Non-members cannot receive tokens, but can send tokens to valid members
    /// @param  validUntil Timestamp until which the user will be a valid member
    function updateMember(address token, address user, uint64 validUntil) external;

    /// @notice Returns whether the user is a valid member of the token
    function isMember(address token, address user) external view returns (bool isValid, uint64 validUntil);
}
