// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IEndorsements} from "../../core/spoke/interfaces/IEndorsements.sol";
import {IScheduleAuth} from "../../core/messaging/interfaces/IScheduleAuth.sol";
import {IProtocolPauser} from "../../core/messaging/interfaces/IProtocolPauser.sol";

interface IRoot is IEndorsements, IProtocolPauser, IScheduleAuth {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event File(bytes32 indexed what, uint256 data);
    event RelyContract(address indexed target, address indexed user);
    event DenyContract(address indexed target, address indexed user);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error DelayTooLong();
    error FileUnrecognizedParam();
    error TargetNotScheduled();
    error TargetNotReady();

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the current timelock for adding new wards
    function delay() external view returns (uint256);

    /// @notice Trusted contracts within the system
    function endorsements(address target) external view returns (uint256);

    /// @notice Returns when `relyTarget` has passed the timelock
    function schedule(address relyTarget) external view returns (uint256 timestamp);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'delay'
    function file(bytes32 what, uint256 data) external;

    //----------------------------------------------------------------------------------------------
    // Endorsements
    //----------------------------------------------------------------------------------------------

    /// @notice Endorses the `user`
    /// @dev    Endorsed users are trusted contracts in the system. They are allowed to bypass
    ///         token restrictions (e.g. the Escrow can automatically receive share class tokens by being endorsed), and
    ///         can automatically set operators in ERC-7540 vaults (e.g. the VaultRouter) is always an operator.
    function endorse(address user) external;

    /// @notice Removes the endorsed user
    function veto(address user) external;

    //----------------------------------------------------------------------------------------------
    // Pause management
    //----------------------------------------------------------------------------------------------

    /// @notice Pause any contracts that depend on `Root.paused()`
    function pause() external;

    /// @notice Unpause any contracts that depend on `Root.paused()`
    function unpause() external;

    //----------------------------------------------------------------------------------------------
    // Timelocked ward management
    //----------------------------------------------------------------------------------------------

    /// @notice Execute a scheduled rely
    /// @dev    Can be triggered by anyone since the scheduling is protected
    function executeScheduledRely(address target) external;

    //----------------------------------------------------------------------------------------------
    // External contract ward management
    //----------------------------------------------------------------------------------------------

    /// @notice Make an address a ward on any contract that Root is a ward on
    function relyContract(address target, address user) external;

    /// @notice Removes an address as a ward on any contract that Root is a ward on
    function denyContract(address target, address user) external;
}
