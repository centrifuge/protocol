// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

// Recon Deps
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {console2} from "forge-std/console2.sol";

// Dependencies
import {AsyncVault} from "src/vaults/AsyncVault.sol";

import {Properties} from "../properties/Properties.sol";

abstract contract DoomsdayTargets is BaseTargetFunctions, Properties {
    
    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision
    function doomsday_deposit_ppfs(uint256 assets) public updateGhosts {
        uint256 ppfsBefore = vault.pricePerShare();

        vm.prank(_getActor());
        uint256 sharesReceived = vault.deposit(assets, _getActor());
        uint256 sharesAsAssets = vault.convertToAssets(sharesReceived);

        eq(sharesAsAssets, (assets / ppfsBefore) + (10 ** token.decimals()), "sharesAsAssets != assets");
        eq(sharesReceived, (assets * ppfsBefore) - (10 ** token.decimals()), "sharesReceived != pricePerShare - precision");
    }

     /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision
    function doomsday_mint_ppfs(uint256 shares) public updateGhosts {
        uint256 ppfsBefore = vault.pricePerShare();

        vm.prank(_getActor());
        uint256 assetsSpent = vault.mint(shares, _getActor());
        uint256 assetsAsShares = vault.convertToShares(assetsSpent);

        eq(assetsSpent, (shares / ppfsBefore) + (10 ** token.decimals()), "assetsSpent != pricePerShare + precision");
        eq(assetsAsShares, (shares * ppfsBefore) - (10 ** token.decimals()), "assetsAsShares != pricePerShare - precision");
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision
    function doomsday_redeem_ppfs(uint256 shares) public updateGhosts {
        uint256 ppfsBefore = vault.pricePerShare();

        vm.prank(_getActor());
        uint256 assetsReceived = vault.redeem(shares, _getActor(), _getActor());
        uint256 assetsAsShares = vault.convertToAssets(shares);

        eq(assetsReceived, (shares / ppfsBefore) + (10 ** token.decimals()), "assetsReceived != pricePerShare + precision");
        eq(assetsAsShares, (shares * ppfsBefore) - (10 ** token.decimals()), "assetsAsShares != pricePerShare - precision");
    }

    /// @dev Property: user pays pricePerShare + precision, the amount of shares user receives should be pricePerShare - precision
    function doomsday_withdraw_ppfs(uint256 assets) public updateGhosts {
        uint256 ppfsBefore = vault.pricePerShare();

        vm.prank(_getActor());
        uint256 sharesReceived = vault.withdraw(assets, _getActor(), _getActor());
        uint256 sharesAsAssets = vault.convertToShares(sharesReceived);

        eq(sharesAsAssets, (assets / ppfsBefore) + (10 ** token.decimals()), "sharesAsAssets != pricePerShare + precision");
        eq(sharesReceived, (assets * ppfsBefore) - (10 ** token.decimals()), "sharesReceived != pricePerShare - precision");
    }
}
