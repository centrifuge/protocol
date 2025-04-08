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
}