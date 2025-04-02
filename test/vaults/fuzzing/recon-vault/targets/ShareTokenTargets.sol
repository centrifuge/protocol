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
abstract contract ShareTokenTargets is BaseTargetFunctions, Properties {
    function token_transfer(address to, uint256 value) public {
        require(_canDonate(to), "never donate to escrow");

        // Clamp
        value = between(value, 0, token.balanceOf(actor));

        bool hasReverted;

        vm.prank(_getActor());
        try token.transfer(to, value) {
            // NOTE: We're not checking for specifics!
        } catch {
            // NOTE: May revert for a myriad of reasons!
            hasReverted = true;
        }

        // TT-1 Always revert if one of them is frozen
        if (
            restrictedTransfers.isFrozen(address(token), to) == true
                || restrictedTransfers.isFrozen(address(token), actor) == true
        ) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Not a member | NOTE: Non member actor and from can move tokens?
        (bool isMember,) = restrictedTransfers.isMember(address(token), to);
        if (!isMember) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }

    // NOTE: We need this for transferFrom to work
    function token_approve(address spender, uint256 value) public asActor {
        token.approve(spender, value);
    }

    // Check
    function token_transferFrom(address from, address to, uint256 value) public {
        address from = _getActor();
        require(_canDonate(to), "never donate to escrow");

        value = between(value, 0, token.balanceOf(from));

        bool hasReverted;
        vm.prank(from);
        try token.transferFrom(from, to, value) {
            // NOTE: We're not checking for specifics!
        } catch {
            // NOTE: May revert for a myriad of reasons!
            hasReverted = true;
        }

        // TT-1 Always revert if one of them is frozen
        if (
            restrictedTransfers.isFrozen(address(token), to) == true
                || restrictedTransfers.isFrozen(address(token), from) == true
        ) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Not a member | NOTE: Non member actor and from can move tokens?
        (bool isMember,) = restrictedTransfers.isMember(address(token), to);
        if (!isMember) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }

    function token_mint(address to, uint256 value) public notGovFuzzing {
        require(_canDonate(to), "never donate to escrow");

        bool hasReverted;

        vm.prank(_getActor());
        try token.mint(to, value) {
            shareMints[address(token)] += value;
        } catch {
            hasReverted = true;
        }

        if (restrictedTransfers.isFrozen(address(token), to) == true) {
            t(hasReverted, "TT-1 Must Revert");
        }

        // Not a member
        (bool isMember,) = restrictedTransfers.isMember(address(token), to);
        if (!isMember) {
            t(hasReverted, "TT-3 Must Revert");
        }
    }
}