// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IAuth {
    event Rely(address indexed user);
    event Deny(address indexed user);

    error NotAuthorized();

    /// @notice Returns whether the target is a ward (has admin access)
    /// @param target The address to check for ward status
    /// @return The ward status (1 if ward, 0 if not)
    function wards(address target) external view returns (uint256);

    /// @notice Make user a ward (give them admin access)
    /// @param user The address to grant ward status to
    function rely(address user) external;

    /// @notice Remove user as a ward (remove admin access)
    /// @param user The address to remove ward status from
    function deny(address user) external;
}
