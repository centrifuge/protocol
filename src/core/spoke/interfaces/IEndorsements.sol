// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IEndorsements {
    event Endorse(address indexed user);
    event Veto(address indexed user);

    /// @notice Returns whether the user is endorsed
    /// @param user The address to check for endorsement status
    /// @return True if the user is endorsed, false otherwise
    function endorsed(address user) external view returns (bool);
}
