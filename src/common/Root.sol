// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRoot} from "./interfaces/IRoot.sol";

import {Auth} from "../misc/Auth.sol";
import {IAuth} from "../misc/interfaces/IAuth.sol";

/// @title  Root
/// @notice Core contract that is a ward on all other deployed contracts.
/// @dev    Pausing can happen instantaneously, but relying on other contracts
///         is restricted to the timelock set by the delay.
contract Root is Auth, IRoot {
    /// @dev To prevent filing a delay that would block any updates indefinitely
    uint256 internal constant MAX_DELAY = 4 weeks;

    bool public paused;
    uint256 public delay;
    mapping(address => uint256) public endorsements;
    mapping(address relyTarget => uint256 timestamp) public schedule;

    constructor(uint256 _delay, address deployer) Auth(deployer) {
        require(_delay <= MAX_DELAY, DelayTooLong());
        delay = _delay;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRoot
    function file(bytes32 what, uint256 data) external auth {
        if (what == "delay") {
            require(data <= MAX_DELAY, DelayTooLong());
            delay = data;
        } else {
            revert FileUnrecognizedParam();
        }
        emit File(what, data);
    }

    /// @inheritdoc IRoot
    function endorse(address user) external auth {
        endorsements[user] = 1;
        emit Endorse(user);
    }

    /// @inheritdoc IRoot
    function veto(address user) external auth {
        endorsements[user] = 0;
        emit Veto(user);
    }

    /// @inheritdoc IRoot
    function endorsed(address user) external view returns (bool) {
        return endorsements[user] == 1;
    }

    //----------------------------------------------------------------------------------------------
    // Pause management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRoot
    function pause() external auth {
        paused = true;
        emit Pause();
    }

    /// @inheritdoc IRoot
    function unpause() external auth {
        paused = false;
        emit Unpause();
    }

    //----------------------------------------------------------------------------------------------
    // Timelocked ward management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRoot
    function scheduleRely(address target) external auth {
        schedule[target] = block.timestamp + delay;
        emit ScheduleRely(target, schedule[target]);
    }

    /// @inheritdoc IRoot
    function cancelRely(address target) external auth {
        require(schedule[target] != 0, TargetNotScheduled());
        schedule[target] = 0;
        emit CancelRely(target);
    }

    /// @inheritdoc IRoot
    function executeScheduledRely(address target) external {
        require(schedule[target] != 0, TargetNotScheduled());
        require(schedule[target] <= block.timestamp, TargetNotReady());

        wards[target] = 1;
        emit Rely(target);

        schedule[target] = 0;
    }

    //----------------------------------------------------------------------------------------------
    // External contract ward management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IRoot
    function relyContract(address target, address user) external auth {
        IAuth(target).rely(user);
        emit RelyContract(target, user);
    }

    /// @inheritdoc IRoot
    function denyContract(address target, address user) external auth {
        IAuth(target).deny(user);
        emit DenyContract(target, user);
    }
}
