// SPDX-License-Identifier: AGPL-3.0-only
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

    // Generic (unclamped)
    function restrictionManager_updateMember(address user, uint64 validUntil) public notGovFuzzing updateBeforeAfter {
        restrictionManager.updateMember(address(trancheToken), user, validUntil);
    }

    // Clamped to current actor
    function restrictionManager_updateMemberBasic(uint64 validUntil) public notGovFuzzing updateBeforeAfter {
        restrictionManager_updateMember(_getActor(), validUntil);
    }

    function restrictionManager_freeze(address user) public notGovFuzzing updateBeforeAfter {
        restrictionManager.freeze(address(trancheToken), user);
    }

    function restrictionManager_freeze_clamped() public notGovFuzzing updateBeforeAfter {
        restrictionManager_freeze(_getActor());
    }

    function restrictionManager_unfreeze(address user) public notGovFuzzing updateBeforeAfter {
        restrictionManager.unfreeze(address(trancheToken), user);
    }

    function restrictionManager_unfreeze() public notGovFuzzing updateBeforeAfter {
        restrictionManager_unfreeze(_getActor());
    }

    /**
     * END RESTRICTION MANAGER
     */
}
