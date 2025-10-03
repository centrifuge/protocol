// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

import {Properties} from "test/integration/recon-end-to-end/properties/Properties.sol";

abstract contract ToggleTargets is BaseTargetFunctions, Properties {
    /// === Helpers === ///
    /// @dev helper to toggle the isLiability boolean for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too
    /// deep error
    function toggle_IsLiability() public {
        IS_LIABILITY = !IS_LIABILITY;
    }

    /// @dev helper to toggle the isIncrease boolean for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too
    /// deep error
    function toggle_IsIncrease() public {
        IS_INCREASE = !IS_INCREASE;
    }

    /// @dev helper to toggle the accountToUpdate uint8 for testing
    /// @dev this is defined like this because implementing it directly as a param in the functions throws a stack too
    /// deep error
    function toggle_AccountToUpdate(uint8 accountToUpdate) public {
        ACCOUNT_TO_UPDATE = createdAccountIds[accountToUpdate % createdAccountIds.length];
    }

    function toggle_AssetAccount(uint32 assetAccountAsUint) public {
        ASSET_ACCOUNT = assetAccountAsUint;
    }

    function toggle_EquityAccount(uint32 equityAccountAsUint) public {
        EQUITY_ACCOUNT = equityAccountAsUint;
    }

    function toggle_LossAccount(uint32 lossAccountAsUint) public {
        LOSS_ACCOUNT = lossAccountAsUint;
    }

    function toggle_GainAccount(uint32 gainAccountAsUint) public {
        GAIN_ACCOUNT = gainAccountAsUint;
    }

    function toggle_IsDebitNormal() public {
        IS_DEBIT_NORMAL = !IS_DEBIT_NORMAL;
    }

    function toggle_MaxClaims(uint32 maxClaims) public {
        MAX_CLAIMS = maxClaims;
    }
}
