// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

import {Properties} from "../properties/Properties.sol";

// Only for Share
abstract contract FullRestrictionsTargets is BaseTargetFunctions, Properties {
    /**
     * RESTRICTION MANAGER
     */
    // NOTE: Same idea that we cycle through values via modifier

    // TODO: Actory Cycling
    function fullRestrictions_updateMemberBasic(uint64 validUntil) public asAdmin {
        fullRestrictions.updateMember(address(token), _getActor(), validUntil);
    }

    // TODO: We prob want to keep one generic
    // And one with limited actors
    function fullRestrictions_updateMember(address user, uint64 validUntil) public asAdmin {
        fullRestrictions.updateMember(address(token), user, validUntil);
    }

    // TODO: Actor Cycling
    function fullRestrictions_freeze(address /*user*/ ) public asAdmin {
        fullRestrictions.freeze(address(token), _getActor());
    }

    function fullRestrictions_unfreeze(address /*user*/ ) public asAdmin {
        fullRestrictions.unfreeze(address(token), _getActor());
    }

    /**
     * END RESTRICTION MANAGER
     */
}
