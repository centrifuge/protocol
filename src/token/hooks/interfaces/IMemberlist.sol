// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title  IMemberlist
/// @notice A per-token memberlist: each member is valid until a timestamp.
interface IMemberlist {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event UpdateMember(address indexed token, address indexed user, uint64 validUntil);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidValidUntil();
    error EndorsedUserCannotBeUpdated();

    //----------------------------------------------------------------------------------------------
    // Managing members
    //----------------------------------------------------------------------------------------------

    /// @notice Add or update a member. Which movements ask for membership is up to the hook
    /// @param validUntil Timestamp until which the user will be a valid member
    function updateMember(address token, address user, uint64 validUntil) external;

    /// @notice Returns whether the user is a valid member of the token
    function isMember(address token, address user) external view returns (bool isValid, uint64 validUntil);
}
