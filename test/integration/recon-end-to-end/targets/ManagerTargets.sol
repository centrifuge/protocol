// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Panic} from "@recon/Panic.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";

// Target functions that are effectively inherited from the Actor and AssetManagers
// Once properly standardized, managers will expose these by default
// Keeping them out makes your project more custom
abstract contract ManagerTargets is BaseTargetFunctions, Properties {
    /// @dev Start acting as another actor
    function switch_actor(uint256 entropy) public {
        _switchActor(entropy);
    }

    /// @dev Starts using a new asset
    function switch_asset(uint256 entropy) public {
        _switchAsset(entropy);
    }

    /// @dev Starts using a new pool
    function switch_pool(uint256 entropy) public {
        _switchPool(entropy);
    }

    /// @dev Starts using a new share class
    function switch_share_class(uint256 entropy) public {
        _switchShareClassId(entropy);
    }

    /// @dev Starts using a new assetId
    function switch_asset_id(uint256 entropy) public {
        _switchAssetId(entropy);
    }

    /// @dev Starts using a new vault
    /// @notice We `updateGhosts` so we can know if the vault changed
    function switch_vault(uint256 entropy) public updateGhosts {
        _switchVault(entropy);
    }

    /// @dev Starts using a new shareToken
    function switch_share_token(uint256 entropy) public {
        _switchShareToken(entropy);
    }

    /// @dev Deploy a new token and add it to the list of assets, then set it as the current asset
    function add_new_asset(uint8 decimals) public returns (address) {
        address newAsset = _newAsset(decimals);
        return newAsset;
    }

    /// === GHOST UPDATING HANDLERS ===///
    /// We `updateGhosts` cause you never know (e.g. donations)
    /// If you don't want to track donations, remove the `updateGhosts`

    /// @dev Approve to arbitrary address, uses Actor by default
    /// NOTE: You're almost always better off setting approvals in `Setup`
    function asset_approve(address to, uint128 amt) public updateGhosts asActor {
        MockERC20(_getAsset()).approve(to, amt);
    }

    /// @dev Mint to arbitrary address, uses owner by default, even though MockERC20 doesn't check
    function asset_mint(address to, uint128 amt) public updateGhosts asAdmin {
        // PoolId poolId = IBaseVault(_getVault()).poolId();
        address poolEscrow = address(poolEscrowFactory.escrow(IBaseVault(_getVault()).poolId()));

        require(to != address(globalEscrow) && to != poolEscrow, "Cannot mint to globalEscrow or poolEscrow");
        MockERC20(_getAsset()).mint(to, amt);
    }
}
