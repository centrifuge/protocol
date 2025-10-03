// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IEndorsements {
    event Endorse(address indexed user);
    event Veto(address indexed user);

    /// @notice Returns whether the user is endorsed
    function endorsed(address user) external view returns (bool);
}
