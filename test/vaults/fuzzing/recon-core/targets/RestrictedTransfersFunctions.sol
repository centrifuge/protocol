// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "../Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

// Only for Share
abstract contract RestrictedTransfersFunctions is BaseTargetFunctions, Properties {
    /**
     * RESTRICTION MANAGER
     */
    // NOTE: Same idea that we cycle through values via modifier

    // TODO: Actory Cycling
    function restrictionManager_updateMemberBasic(uint64 validUntil) public {
        restrictionManager.updateMember(address(token), actor, validUntil);
    }

    // TODO: We prob want to keep one generic
    // And one with limited actors
    function restrictionManager_updateMember(address user, uint64 validUntil) public {
        restrictionManager.updateMember(address(token), user, validUntil);
    }

    // TODO: Actor Cycling
    function restrictionManager_freeze(address /*user*/ ) public {
        restrictionManager.freeze(address(token), actor);
    }

    function restrictionManager_unfreeze(address /*user*/ ) public {
        restrictionManager.unfreeze(address(token), actor);
    }

    /**
     * END RESTRICTION MANAGER
     */
}
