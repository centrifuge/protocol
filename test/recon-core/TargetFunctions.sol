// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "./Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {ERC7540Vault} from "src/vaults/ERC7540Vault.sol";

// Component
import {TrancheTokenFunctions} from "./targets/TrancheTokenFunctions.sol";
import {GatewayMockFunctions} from "./targets/GatewayMockFunctions.sol";
import {RestrictionManagerFunctions} from "./targets/RestrictionManagerFunctions.sol";
import {VaultFunctions} from "./targets/VaultFunctions.sol";
import {PoolManagerFunctions} from "./targets/PoolManagerFunctions.sol";
import {VaultCallbacks} from "./targets/VaultCallbacks.sol";

abstract contract TargetFunctions is
    BaseTargetFunctions,
    Properties,
    TrancheTokenFunctions,
    GatewayMockFunctions,
    RestrictionManagerFunctions,
    VaultFunctions,
    PoolManagerFunctions,
    VaultCallbacks
{
    /**
     * TODO: Port Over tranche, liquidity pool stuff
     *
     *
     */

    /**
     * INVESTOR CANARIES
     */
    function canary_doesTokenGetDeployed() public updateBeforeAfter {
        if (RECON_TOGGLE_CANARY_TESTS) {
            lt(allTokens.length, 10, "allTokens.length >= 10");
        }
    }

    function canary_doesTranchesGetDeployed() public updateBeforeAfter {
        if (RECON_TOGGLE_CANARY_TESTS) {
            lt(trancheTokens.length, 10, "trancheTokens.length >= 10");
        }
    }

    function canary_doesVaultsGetDeployed() public updateBeforeAfter {
        if (RECON_TOGGLE_CANARY_TESTS) {
            lt(vaults.length, 10, "vaults.length >= 10");
        }
    }

    function canary_doesNonDefaultActorDeposit() public updateBeforeAfter {
        if (RECON_TOGGLE_CANARY_TESTS && _getActor() != address(this)) {
            (, uint256 maxWithdraw,,,,,,,,) = investmentManager.investments(address(vault), _getActor());
            lt(maxWithdraw, 0, "non-default actor deposits");
        }
    }

    /// == UTILITY == //
    function target_switchActor(uint256 entropy) public updateBeforeAfter {
        address randomActor = _getRandomActor(entropy);
        _enableActor(randomActor);
    }
}
