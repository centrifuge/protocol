// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

import {MockERC20} from "@recon/MockERC20.sol";

import {PoolId, AccountId} from "src/hub/interfaces/IHub.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../Properties.sol";

abstract contract DoomsdayTargets is
    BaseTargetFunctions,
    Properties
{

    /// @dev Property: accounting.accountValue should never revert
    function accounting_accountValue(uint64 poolIdAsUint, uint32 accountAsInt) public {
        PoolId poolId = PoolId.wrap(poolIdAsUint);
        AccountId account = AccountId.wrap(accountAsInt);
        
        try accounting.accountValue(poolId, account) {
        } catch (bytes memory reason) {
            bool expectedRevert = checkError(reason, "AccountDoesNotExist()");
            t(expectedRevert, "accountValue should never revert");
        }
    }

    /// @dev Differential fuzz test for accounting.accountValue calculation
    function accounting_accountValue_differential(uint128 totalDebit, uint128 totalCredit) public {
        // using totalDebit - totalCredit but since these values are fuzzed, this also represents all possible totalCredit - totalDebit values
        int128 valueFromInt;
        uint128 valueFromUint;
        bool valueFromIntReverts;
        bool valueFromUintReverts;

        try mockAccountValue.valueFromInt(totalDebit, totalCredit) returns (int128 result) {
            valueFromInt = result;
        } catch (bytes memory reason) {
            valueFromIntReverts = true;
        }

        try mockAccountValue.valueFromUint(totalDebit, totalCredit) returns (uint128 result) {
            valueFromUint = result;
        } catch (bytes memory reason) {
            valueFromUintReverts = true;
        }

        // precondition: valueFromInt should only revert if valueFromUint also does
        t(!(valueFromIntReverts && !valueFromUintReverts), "valueFromInt should only revert if valueFromUint also does");
        t(valueFromInt == int128(valueFromUint), "valueFromInt and valueFromUint should be equal");
    }
}
