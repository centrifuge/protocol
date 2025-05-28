// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";

import {Properties} from "../properties/Properties.sol";

// Only for Share
abstract contract RestrictedTransfersTargets is BaseTargetFunctions, Properties {
    /**
     * RESTRICTION MANAGER
     */
    // NOTE: Same idea that we cycle through values via modifier

    function restrictedTransfers_updateMemberBasic(uint64 validUntil) public asAdmin {
        fullRestrictions.updateMember(_getShareToken(), _getActor(), validUntil);
    }

    // TODO: We prob want to keep one generic
    // And one with limited actors
    function restrictedTransfers_updateMember(address user, uint64 validUntil) public asAdmin {
        fullRestrictions.updateMember(_getShareToken(), user, validUntil);
    }

    function restrictedTransfers_freeze() public asAdmin {
        fullRestrictions.freeze(_getShareToken(), _getActor());
    }

    function restrictedTransfers_unfreeze() public asAdmin {
        fullRestrictions.unfreeze(_getShareToken(), _getActor());
    }

    /**
     * END RESTRICTION MANAGER
     */
}
