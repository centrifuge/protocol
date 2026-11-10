// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {IAccounting} from "../../../../src/core/hub/interfaces/IAccounting.sol";

import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

/// @notice Stateless checks over an arbitrary input.
abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    /// @dev `accountValue` never reverts for an account that exists, and reverts only with
    ///      `AccountDoesNotExist` for one that does not.
    function doomsday_accountValue(uint32 account) public {
        AccountId accountId = AccountId.wrap(account % 8);
        try accounting.accountValue(poolA, accountId) {}
        catch (bytes memory err) {
            t(bytes4(err) == IAccounting.AccountDoesNotExist.selector, "accountValue reverted unexpectedly");
            t(!accounting.exists(poolA, accountId), "accountValue reverted for an existing account");
        }
    }
}
