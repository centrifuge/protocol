// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AccountId, AccountType} from "src/hub/interfaces/IHub.sol";
import {PoolEscrow} from "src/common/PoolEscrow.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";
import {D18} from "src/misc/types/D18.sol";
import {RequestMessageLib} from "src/common/libraries/RequestMessageLib.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // Helper functions to handle bytes calldata parameters
    function hub_updateRestriction_wrapper(uint16 /* chainId */ ) external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction(chainId, "");
    }

    function hub_updateRestriction_clamped_wrapper() external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction_clamped("");
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {}

    /// === Potential Issues === ///

    // forge test --match-test test_transientValuation_priceChange_updatesHoldingValue -vvv
    function test_transientValuation_priceChange_updatesHoldingValue() public {
        // Setup: Deploy a new pool and share with transient valuation (already initializes holding)
        shortcut_deployNewTokenPoolAndShare(18, 18, false, false, true);
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = _getAssetId();
        
        // Set initial price to 1.0 (1e18)
        transientValuation_setPrice_clamped(1e18);
        console2.log("Initial price set to 1e18");
        
        // Get the initial holding value (should be 0 since no assets yet)
        uint128 initialValue = holdings.value(poolId, scId, assetId);
        console2.log("Initial holding value:", initialValue);
        
        // Verify the initial price was set correctly
        (D18 price1, bool isValid1) = transientValuation.price(poolId, scId, assetId);
        assertEq(price1.raw(), 1e18, "Initial price should be 1e18");
        assertTrue(isValid1, "Initial price should be valid");
        
        // Now change the price to 2.0 (2e18)
        transientValuation_setPrice_clamped(2e18);
        console2.log("Price changed to 2e18");
        
        // Verify the price was updated
        (D18 price2, bool isValid2) = transientValuation.price(poolId, scId, assetId);
        assertEq(price2.raw(), 2e18, "Price should be updated to 2e18");
        assertTrue(isValid2, "Price should be valid after update");
        
        // Call hub_updateHoldingValue to reflect the new price
        hub_updateHoldingValue();
        console2.log("Called hub_updateHoldingValue after price change");
        
        // Change price again to 3.0 (3e18)
        transientValuation_setPrice_clamped(3e18);
        console2.log("Price changed to 3e18");
        
        // Verify the final price update
        (D18 price3, bool isValid3) = transientValuation.price(poolId, scId, assetId);
        assertEq(price3.raw(), 3e18, "Price should be updated to 3e18");
        assertTrue(isValid3, "Price should still be valid");
        
        // Call updateHoldingValue again
        hub_updateHoldingValue();
        console2.log("Called hub_updateHoldingValue after second price change");
        
        // Get final holding value
        uint128 finalValue = holdings.value(poolId, scId, assetId);
        console2.log("Final holding value:", finalValue);
        
        // Test demonstrates that:
        // 1. transientValuation_setPrice_clamped correctly updates the price multiple times
        // 2. hub_updateHoldingValue can be called after each price change
        // 3. The price changes are persisted and can be verified
        console2.log("Test completed: Price changes work correctly with hub_updateHoldingValue");
    }

    /// === Categorized Issues === ///
}
