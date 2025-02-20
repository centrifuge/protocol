// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/vaults/token/ERC20.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";

// Only for Tranche
abstract contract RestrictionManagerFunctions is BaseTargetFunctions, Properties {
    /**
     * RESTRICTION MANAGER
     */
    // NOTE: Same idea that we cycle through values via modifier

    // TODO: Actory Cycling
    function restrictionManager_updateMemberBasic(uint64 validUntil) public {
        restrictionManager.updateMember(address(trancheToken), actor, validUntil);
    }

    // TODO: We prob want to keep one generic
    // And one with limited actors
    function restrictionManager_updateMember(address user, uint64 validUntil) public {
        restrictionManager.updateMember(address(trancheToken), user, validUntil);
    }

    // TODO: Actor Cycling
    function restrictionManager_freeze(address /*user*/ ) public {
        restrictionManager.freeze(address(trancheToken), actor);
    }

    function restrictionManager_unfreeze(address /*user*/ ) public {
        restrictionManager.unfreeze(address(trancheToken), actor);
    }

    /**
     * END RESTRICTION MANAGER
     */
}
