// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

// Test Utils
import {Properties} from "../properties/Properties.sol";

// Only for Share
abstract contract ShareTokenTargets is BaseTargetFunctions, Properties {
    /// @dev Property: must revert if sending to or from a frozen user
    /// @dev Property: must revert if sending to a non-member who is not endorsed
    function token_transfer(address to, uint256 value) public updateGhosts {
        require(_canDonate(to), "never donate to escrow");

        // Clamp
        value = between(value, 0, IShareToken(_getShareToken()).balanceOf(_getActor()));

        bool hasReverted;

        vm.prank(_getActor());
        try IShareToken(_getShareToken()).transfer(to, value) {
            // NOTE: We're not checking for specifics!
        } catch {
            // NOTE: May revert for a myriad of reasons!
            hasReverted = true;
        }

        // TT-1 Always revert if one of them is frozen
        if (
            fullRestrictions.isFrozen(_getShareToken(), to) == true
                || fullRestrictions.isFrozen(_getShareToken(), _getActor()) == true
        ) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Not a member | NOTE: Non member actor and from can move tokens?
        (bool isMember,) = fullRestrictions.isMember(_getShareToken(), to);
        bool endorsed = root.endorsed(to);
        if (!isMember && value > 0 && !endorsed) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }

    // NOTE: We need this for transferFrom to work
    function token_approve(address spender, uint256 value) public updateGhosts asActor {
        IShareToken(_getShareToken()).approve(spender, value);
    }

    /// @dev Property: must revert if sending to or from a frozen user
    /// @dev Property: must revert if sending to a non-member who is not endorsed
    function token_transferFrom(address to, uint256 value) public updateGhosts {
        require(_canDonate(to), "never donate to escrow");

        value = between(value, 0, IShareToken(_getShareToken()).balanceOf(_getActor()));

        bool hasReverted;
        vm.prank(_getActor());
        try IShareToken(_getShareToken()).transferFrom(_getActor(), to, value) {
            // NOTE: We're not checking for specifics!
        } catch {
            // NOTE: May revert for a myriad of reasons!
            hasReverted = true;
        }

        // TT-1 Always revert if one of them is frozen
        if (
            fullRestrictions.isFrozen(_getShareToken(), to) == true
                || fullRestrictions.isFrozen(_getShareToken(), _getActor()) == true
        ) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Recipient is not a member | NOTE: Non member actor and from can move tokens?
        (bool isMember,) = fullRestrictions.isMember(_getShareToken(), to);
        bool endorsed = root.endorsed(to);
        if (!isMember && value > 0 && !endorsed) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }

    // NOTE: Removed because breaks solvency properties by allowing unrealistic minting
    // function token_mint(address to, uint256 value) public notGovFuzzing {
    //     require(_canDonate(to), "never donate to escrow");

    //     bool hasReverted;

    //     vm.prank(_getActor());
    //     try token.mint(to, value) {
    //         shareMints[address(token)] += value;
    //     } catch {
    //         hasReverted = true;
    //     }

    //     if (restrictedTransfers.isFrozen(address(token), to) == true) {
    //         t(hasReverted, "TT-1 Must Revert");
    //     }

    //     // Not a member
    //     (bool isMember,) = restrictedTransfers.isMember(address(token), to);
    //     if (!isMember) {
    //         t(hasReverted, "TT-3 Must Revert");
    //     }
    // }
}
