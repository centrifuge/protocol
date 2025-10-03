// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface IProtocolPauser {
    event Pause();
    event Unpause();

    /// @notice Returns whether the root is paused
    function paused() external view returns (bool);
}
