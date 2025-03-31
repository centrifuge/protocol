// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";

// Only for Tranche
abstract contract RestrictionManagerFunctions is BaseTargetFunctions, Properties {
    /**
     * RESTRICTION MANAGER
     */
    // NOTE: Same idea that we cycle through values via modifier

    function restrictionManager_updateMemberBasic(uint64 validUntil) public notGovFuzzing updateGhosts asAdmin {
        restrictionManager.updateMember(address(trancheToken), _getActor(), validUntil);
    }

    // TODO: We prob want to keep one generic
    // And one with limited actors
    function restrictionManager_updateMember(address user, uint64 validUntil) public notGovFuzzing updateGhosts asAdmin {
        restrictionManager.updateMember(address(trancheToken), user, validUntil);
    }

    function restrictionManager_freeze(address /*user*/ ) public notGovFuzzing updateGhosts asAdmin {
        restrictionManager.freeze(address(trancheToken), _getActor());
    }

    function restrictionManager_unfreeze(address /*user*/ ) public notGovFuzzing updateGhosts asAdmin {
        restrictionManager.unfreeze(address(trancheToken), _getActor());
    }

    /**
     * END RESTRICTION MANAGER
     */
}
