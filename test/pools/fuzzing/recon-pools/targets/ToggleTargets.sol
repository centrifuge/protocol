// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

import {MockERC20} from "@recon/MockERC20.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

abstract contract ToggleTargets is
    BaseTargetFunctions,
    Properties
{
    /// === Helpers === ///
    /// @dev helper to toggle the isLiability boolean for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too deep error
    function toggle_IsLiability() public {
        IS_LIABILITY = !IS_LIABILITY;
    }

    /// @dev helper to toggle the isIncrease boolean for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too deep error
    function toggle_IsIncrease() public {
        IS_INCREASE = !IS_INCREASE;
    }

    /// @dev helper to toggle the accountToUpdate uint8 for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too deep error
    function toggle_AccountToUpdate(uint8 accountToUpdate) public {
        ACCOUNT_TO_UPDATE = accountToUpdate;
    }
}