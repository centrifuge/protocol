// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {Properties} from "./Properties.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

// Component
import {ShareTokenFunctions} from "./targets/ShareTokenFunctions.sol";
import {GatewayMockFunctions} from "./targets/GatewayMockFunctions.sol";
import {RestrictionManagerFunctions} from "./targets/RestrictionManagerFunctions.sol";
import {VaultFunctions} from "./targets/VaultFunctions.sol";
import {PoolManagerFunctions} from "./targets/PoolManagerFunctions.sol";
import {VaultCallbacks} from "./targets/VaultCallbacks.sol";

abstract contract TargetFunctions is
    BaseTargetFunctions,
    Properties,
    ShareTokenFunctions,
    GatewayMockFunctions,
    RestrictionManagerFunctions,
    VaultFunctions,
    PoolManagerFunctions,
    VaultCallbacks
{
    /**
     * TODO: Port Over share class, liquidity pool stuff
     *
     *
     */

    /**
     * INVESTOR FUNCTIONS
     */
    function invariant_doesTokenGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return allTokens.length < 10;
        }

        return true;
    }

    function invariant_doesSharesGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return shareClassTokens.length < 10;
        }

        return true;
    }

    function invariant_doesVaultsGetDeployed() public view returns (bool) {
        if (RECON_TOGGLE_CANARY_TESTS) {
            return vaults.length < 10;
        }

        return true;
    }
}
