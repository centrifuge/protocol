// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {IRoot, IRecoverable} from "src/common/interfaces/IRoot.sol";

/// @title  Root
/// @notice Core contract that is a ward on all other deployed contracts.
/// @dev    Pausing can happen instantaneously, but relying on other contracts
///         is restricted to the timelock set by the delay.
contract Root is Auth, IRoot {
    using BytesLib for bytes;

    /// @dev To prevent filing a delay that would block any updates indefinitely
    uint256 internal constant MAX_DELAY = 4 weeks;

    /// @inheritdoc IRoot
    bool public paused;

    /// @inheritdoc IRoot
    uint256 public delay;

    /// @inheritdoc IRoot
    mapping(address => uint256) public endorsements;

    /// @inheritdoc IRoot
    mapping(address relyTarget => uint256 timestamp) public schedule;

    constructor(uint256 _delay, address deployer) Auth(deployer) {
        require(_delay <= MAX_DELAY, DelayTooLong());

        delay = _delay;
    }

    // --- Administration ---
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

    /// --- Endorsements ---
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
    function endorsed(address user) public view returns (bool) {
        return endorsements[user] == 1;
    }

    // --- Pause management ---
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

    /// --- Timelocked ward management ---
    /// @inheritdoc IRoot
    function scheduleRely(address target) public auth {
        schedule[target] = block.timestamp + delay;
        emit ScheduleRely(target, schedule[target]);
    }

    /// @inheritdoc IRoot
    function cancelRely(address target) public auth {
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

    /// --- External contract ward management ---
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

    /// --- Token recovery ---
    /// @inheritdoc IRoot
    function recoverTokens(address target, address token, uint256 tokenId, address to, uint256 amount) public auth {
        IRecoverable(target).recoverTokens(token, tokenId, to, amount);
        emit RecoverTokens(target, token, tokenId, to, amount);
    }
}
