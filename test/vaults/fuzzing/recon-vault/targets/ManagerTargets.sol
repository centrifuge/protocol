// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {vm} from "@chimera/Hevm.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

import {MockERC20} from "@recon/MockERC20.sol";

import {BeforeAfter} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";


// Target functions that are effectively inherited from the Actor and AssetManagers
// Once properly standardized, managers will expose these by default
// Keeping them out makes your project more custom
abstract contract ManagerTargets is
    BaseTargetFunctions,
    Properties
{
    // == ACTOR HANDLERS == //
    
    /// @dev Start acting as another actor
    function switch_actor(uint256 entropy) public {
        _switchActor(entropy);
    }


    /// @dev Starts using a new asset
    function switch_asset(uint256 entropy) public {
        _switchAsset(entropy);
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
        require(to != address(escrow), "Cannot mint to escrow");
        MockERC20(_getAsset()).mint(to, amt);
    }

    // NOTE: These are unused because we currently just deploy and switch to entirely new system
    // function changePool() public {
    //     // Given Pool, swap to new pool
    //     // Pool is easy
    //     // But given a Pool, we need to set a Share Class and a Currency
    //     // So we check if they exist, and use them

    //     // If they don't, we still switch
    //     // But we will need medusa to deploy a new Share (and currency)
    // }

    // // TODO: Consider adding ways to deploy
    // // TODO: Check if it's worth having incorrect settings as a means to explore them

    // // Cycle through Shares -> Changes the Share ID without changing the currency
    // function changeShareForPool() public {}

    // // Changes the Currency being used
    // // Keeps the Same Pool
    // // Since it changes the currency, it also changes the share class
    // function changeCurrencyForPool() public {}
}