// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IScheduleAuth {
    event ScheduleRely(address indexed target, uint256 indexed scheduledTime);
    event CancelRely(address indexed target);

    /// @notice Schedule relying a new ward after the delay has passed
    /// @param target The address to schedule as a ward
    function scheduleRely(address target) external;

    /// @notice Cancel a pending scheduled rely
    /// @param target The address to cancel the scheduled rely for
    function cancelRely(address target) external;
}
