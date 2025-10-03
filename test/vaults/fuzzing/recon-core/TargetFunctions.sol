// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";

// Dependencies
import {ERC20} from "src/misc/ERC20.sol";
import {AsyncVault} from "src/vaults/AsyncVault.sol";

// Component
import {ShareTokenTargets} from "./targets/ShareTokenTargets.sol";
import {GatewayMockTargets} from "./targets/GatewayMockTargets.sol";
import {FullRestrictionsTargets} from "./targets/FullRestrictionsTargets.sol";
import {VaultTargets} from "./targets/VaultTargets.sol";
import {PoolManagerTargets} from "./targets/PoolManagerTargets.sol";
import {VaultCallbackTargets} from "./targets/VaultCallbackTargets.sol";
import {ManagerTargets} from "./targets/ManagerTargets.sol";
import {Properties} from "./properties/Properties.sol";

abstract contract TargetFunctions is
    BaseTargetFunctions,
    Properties,
    ShareTokenTargets,
    GatewayMockTargets,
    FullRestrictionsTargets,
    VaultTargets,
    PoolManagerTargets,
    VaultCallbackTargets,
    ManagerTargets
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
            return _getAssets().length < 10;
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
