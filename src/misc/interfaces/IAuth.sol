// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

interface IAuth {
    event Rely(address indexed user);
    event Deny(address indexed user);

    error NotAuthorized();

    /// @notice Returns whether the target is a ward (has admin access)
    function wards(address target) external view returns (uint256);

    /// @notice Make user a ward (give them admin access)
    function rely(address user) external;

    /// @notice Remove user as a ward (remove admin access)
    function deny(address user) external;
}
