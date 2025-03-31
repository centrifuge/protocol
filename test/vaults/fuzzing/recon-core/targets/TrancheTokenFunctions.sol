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
abstract contract TrancheTokenFunctions is BaseTargetFunctions, Properties {
    function trancheToken_transfer(address to, uint256 value) public {
        require(_canDonate(to), "never donate to escrow");

        // Clamp
        value = between(value, 0, trancheToken.balanceOf(_getActor()));

        bool hasReverted;

        try trancheToken.transfer(to, value) {
            // NOTE: We're not checking for specifics!
        } catch {
            // NOTE: May revert for a myriad of reasons!
            hasReverted = true;
        }

        // TT-1 Always revert if one of them is frozen
        if (
            restrictionManager.isFrozen(address(trancheToken), to) == true
                || restrictionManager.isFrozen(address(trancheToken), _getActor()) == true
        ) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Not a member | NOTE: Non member actor and from can move tokens?
        (bool isMember,) = restrictionManager.isMember(address(trancheToken), to);
        if (!isMember) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }

    // NOTE: We need this for transferFrom to work
    function trancheToken_approve(address spender, uint256 value) public {
        trancheToken.approve(spender, value);
    }

    // Check
    function trancheToken_transferFrom(address from, address to, uint256 value) public {
        require(_canDonate(to), "never donate to escrow");

        value = between(value, 0, trancheToken.balanceOf(from));

        bool hasReverted;
        try trancheToken.transferFrom(from, to, value) {
            // NOTE: We're not checking for specifics!
        } catch {
            // NOTE: May revert for a myriad of reasons!
            hasReverted = true;
        }

        // TT-1 Always revert if one of them is frozen
        if (
            restrictionManager.isFrozen(address(trancheToken), to) == true
                || restrictionManager.isFrozen(address(trancheToken), from) == true
        ) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Not a member | NOTE: Non member actor and from can move tokens?
        (bool isMember,) = restrictionManager.isMember(address(trancheToken), to);
        if (!isMember) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }

    function trancheToken_mint(address to, uint256 value) public {
        require(_canDonate(to), "never donate to escrow");

        bool hasReverted;

        try trancheToken.mint(to, value) {
            trancheMints[address(trancheToken)] += value;
        } catch {
            hasReverted = true;
        }

        if (restrictionManager.isFrozen(address(trancheToken), to) == true) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Not a member
        (bool isMember,) = restrictionManager.isMember(address(trancheToken), to);
        if (!isMember) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }
}
