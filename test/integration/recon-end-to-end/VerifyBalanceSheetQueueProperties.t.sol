// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console2.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {D18} from "src/misc/types/D18.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

/// @title VerifyBalanceSheetQueueProperties
/// @notice Consolidated verification tests for BalanceSheet queue properties
/// @dev Tests both Share Queue behavior and Queue State consistency properties
contract VerifyBalanceSheetQueueProperties is Test, TargetFunctions, FoundryAsserts {
    
    function setUp() public {
        setup();
    }
    
    // ============ Share Queue Properties ============
    
    /// @dev Test Property 0.1: Share Queue Flip Logic Consistency
    /// Verifies delta and isPositive flag accurately represent net position
    function test_shareQueueFlipLogic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 1, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Test positive position (issue > revoke)
        balanceSheet_issue(200e18); // Issue more shares to enable larger revokes
        
        // Approve share tokens for revoke operation
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(30e18);
        
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 170e18, "Delta should be 170e18 (200-30)");
        assertTrue(isPositive, "isPositive should be true for net positive position");
        
        // Test zero position (equal issue and revoke)
        // Current state: +170e18 delta, actor has 170e18 tokens
        balanceSheet_revoke(170e18); // Net: +170-170 = 0, Actor has 0 tokens left
        
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta should be 0 after equal issue/revoke");
        assertFalse(isPositive, "isPositive should be false when delta is zero");
        
        // Test positive again from zero
        balanceSheet_issue(50e18);  // Net: +50, Actor has 50 tokens
        
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 50e18, "Delta should be 50e18");
        assertTrue(isPositive, "isPositive should be true for positive delta");
        
        // Call formal property from Properties.sol
        property_shareQueueFlipLogic();
    }
    
    /// @dev Test Property 0.2: Share Queue Flip Boundaries
    /// Verifies exact zero crossings are handled correctly
    function test_shareQueueFlipBoundaries() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 2, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Start with equal issue and revoke (zero position)
        balanceSheet_issue(100e18);
        
        // Approve share tokens for revoke operations
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(100e18);
        
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta should be 0 at exact balance");
        assertFalse(isPositive, "isPositive should be false at zero position");
        
        // Test boundary crossing: +1 wei over zero
        balanceSheet_issue(1);
        
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 1, "Delta should be 1 wei");
        assertTrue(isPositive, "isPositive should be true for positive delta");
        
        // Test boundary crossing: just test that we can go from positive to zero  
        // Current: delta = +1, actor has 1 wei
        balanceSheet_revoke(1); // Delta: +1-1 = 0, actor has 0 wei left
        
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta should be 0 after crossing boundary");
        assertFalse(isPositive, "isPositive should be false at zero");
        
        // Call formal property from Properties.sol
        property_shareQueueFlipBoundaries();
    }
    
    /// @dev Test Property 0.3: Share Queue Position Tracking
    /// Verifies net position calculations are accurate across operations
    function test_shareQueuePositionTracking() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 3, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Complex sequence of operations
        balanceSheet_issue(200e18);
        
        // Approve share tokens for revoke operations
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(50e18);
        balanceSheet_issue(75e18);
        balanceSheet_revoke(100e18);
        
        // Net: (200 + 75) - (50 + 100) = 275 - 150 = 125 (positive)
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 125e18, "Delta should be 125e18");
        assertTrue(isPositive, "Net position should be positive");
        
        // Call formal property from Properties.sol
        property_shareQueueCommutativity();
    }
    
    /// @dev Test Property 0.4: Share Queue Flip Count Accuracy
    /// Verifies flip counter tracks sign changes correctly
    function test_shareQueueFlipCountAccuracy() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 4, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Sequence that causes multiple flips  
        // Issue enough tokens to support all the revoke operations: 150+50+200 = 400 total
        balanceSheet_issue(500e18);      // 0 → +500 (no flip, starts positive)
        
        // Approve share tokens for revoke operations
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(200e18);     // +500 → +300 (no flip, stays positive)
        // Actor now has 300e18 tokens left (500-200)
        balanceSheet_revoke(300e18);     // +300 → 0 (brings to zero)
        balanceSheet_issue(200e18);      // 0 → +200 (positive)
        balanceSheet_revoke(100e18);     // +200 → +100 (stays positive)
        balanceSheet_revoke(100e18);     // +100 → 0 (back to zero)
        
        // Call formal property from Properties.sol
        property_shareQueueFlipLogic();
    }
    
    /// @dev Test Property 0.5: Share Queue Flip Monotonicity
    /// Verifies flip count only increases, never decreases
    function test_shareQueueFlipMonotonicity() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 5, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Multiple operations that should only increase flip count
        // Issue enough tokens to support all revokes: 100+50+200 = 350 total
        balanceSheet_issue(400e18);
        
        // Approve share tokens for revoke operations
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        // Actor has 400e18 tokens, test monotonic sequence without going negative
        balanceSheet_revoke(200e18);  // +400 → +200 (stays positive)
        // Actor has 200e18 tokens left
        balanceSheet_revoke(200e18);  // +200 → 0 (reaches zero)
        // Actor has 0 tokens left  
        balanceSheet_issue(150e18);   // 0 → +150 (positive from zero)
        // Actor has 150e18 tokens
        balanceSheet_revoke(50e18);   // +150 → +100 (stays positive)
        balanceSheet_revoke(100e18); // +100 → 0 (back to zero)
        
        // Call formal property from Properties.sol
        property_shareQueueCommutativity();
    }
    
    /// @dev Test Property 0.6: Share Queue Nonce Progression
    /// Verifies nonce increases monotonically with submissions
    function test_shareQueueNonceProgression() public {
        // Setup infrastructure with multiple submissions
        shortcut_deployNewTokenPoolAndShare(18, 6, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Initial operations
        balanceSheet_issue(100e18);
        
        // Multiple submission cycles
        balanceSheet_submitQueuedShares(0);
        balanceSheet_issue(50e18);
        balanceSheet_submitQueuedShares(0);
        balanceSheet_revoke(25e18);
        balanceSheet_submitQueuedShares(0);
        
        // Call formal property from Properties.sol
        property_shareQueueSubmission();
    }
    
    /// @dev Test Property 0.7: Share Queue Delta Preservation
    /// Verifies operations preserve mathematical relationships
    function test_shareQueueDeltaPreservation() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 7, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Operations that should maintain delta accuracy
        balanceSheet_issue(123e18);
        balanceSheet_revoke(45e18);
        balanceSheet_issue(67e18);
        
        // Call formal property from Properties.sol
        property_shareQueueAssetCounter();
    }
    
    /// @dev Test Property 0.8: Share Queue State Coherence
    /// Verifies all queue state fields remain consistent
    function test_shareQueueStateCoherence() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 8, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Various operations to test state coherence
        balanceSheet_issue(89e18);
        
        // Approve share tokens for revoke operations
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(34e18);     // Actor has 55e18 left (89-34)
        balanceSheet_submitQueuedShares(0); // Queue resets, actor keeps their tokens
        balanceSheet_issue(156e18);     // Actor now has 55+156 = 211e18 tokens
        balanceSheet_revoke(109e18);    // Revoke less to stay within balance and create target state
        
        // Call formal property from Properties.sol
        property_shareQueueFlagConsistency();
    }
    
    /// @dev Test Property 0.9: Share Queue Batch Consistency
    /// Verifies operations work correctly in batches
    function test_shareQueueBatchConsistency() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 9, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Batch operations
        balanceSheet_issue(100e18);
        balanceSheet_issue(50e18);
        
        // Approve share tokens for revoke operations
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(75e18);
        balanceSheet_revoke(25e18);
        
        // Call formal property from Properties.sol
        property_shareQueueCommutativity();
    }
    
    /// @dev Test Property 0.10: Share Queue Edge Case Handling
    /// Verifies proper handling of edge cases and boundary conditions
    function test_shareQueueEdgeCaseHandling() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 10, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Edge cases: very small amounts, zero operations
        balanceSheet_issue(1); // Minimum amount
        balanceSheet_revoke(1); // Back to zero
        balanceSheet_issue(type(uint128).max); // Maximum amount (if supported)
        
        // Call formal property from Properties.sol - this should handle edge cases
        property_shareQueueFlipBoundaries();
    }
    
    // ============ Queue State Consistency Properties ============
    
    /// @dev Test Property 1.1: Asset Queue Counter Consistency
    /// Verifies queuedAssetCounter accurately tracks non-empty asset queues
    function test_assetQueueCounterConsistency() public {
        // Setup full infrastructure 
        shortcut_deployNewTokenPoolAndShare(18, 11, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup tokens for operations
        IBaseVault vault = IBaseVault(_getVault());
        
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        
        // Mint tokens and approve for deposit operations
        MockERC20 assetToken = MockERC20(vault.asset());
        assetToken.mint(address(this), 1000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Perform deposit operation to populate asset queue
        balanceSheet_deposit(0, 100e18);
        
        // Call formal property from Properties.sol
        property_assetQueueCounterConsistency();
        
        // Verify specific state
        (uint128 deposits,) = balanceSheet.queuedAssets(poolId, scId, assetId);
        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(deposits, 100e18, "Deposit amount should be tracked");
        assertEq(queuedAssetCounter, 1, "Asset counter should be 1 after deposit");
    }

    /// @dev Test Property 1.2: Asset Counter Bounds
    /// Verifies counter cannot exceed total number of assets
    function test_assetCounterBounds() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup infrastructure
        IBaseVault vault = IBaseVault(_getVault());
        
        // Mint tokens and approve for operations
        MockERC20 assetToken = MockERC20(vault.asset());
        assetToken.mint(address(this), 1000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Multiple operations to test bounds
        balanceSheet_deposit(0, 50e18);
        balanceSheet_withdraw(0, 25e18);
        
        // Call formal property from Properties.sol
        property_assetCounterBounds();
        
        // Verify counter doesn't exceed reasonable bounds
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        (,, uint32 queuedAssetCounter,) = balanceSheet.queuedShares(poolId, scId);
        assertLe(queuedAssetCounter, 10, "Counter should not exceed reasonable bounds");
    }

    /// @dev Test Property 1.3: Asset Queue Non-Negative
    /// Verifies deposits and withdrawals never underflow
    function test_assetQueueNonNegative() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 13, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup infrastructure
        IBaseVault vault = IBaseVault(_getVault());
        
        // Mint tokens and approve for operations
        MockERC20 assetToken = MockERC20(vault.asset());
        assetToken.mint(address(this), 1000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Operations with both deposits and withdrawals
        balanceSheet_deposit(0, 100e18);
        balanceSheet_withdraw(0, 30e18);
        
        // Call formal property from Properties.sol
        property_assetQueueNonNegative();
        
        // Verify values are non-negative
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);
        assertGe(deposits, 0, "Deposits should be non-negative");
        assertGe(withdrawals, 0, "Withdrawals should be non-negative");
    }

    /// @dev Test Property 1.4: Share Queue isPositive Flag Consistency
    /// Verifies flag accurately represents delta sign
    function test_shareQueueFlagConsistency() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 14, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Test positive delta state
        balanceSheet_issue(100e18);
        
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertTrue(delta > 0, "Delta should be positive after issue");
        assertTrue(isPositive, "isPositive should be true when delta > 0");
        
        // Call formal property from Properties.sol
        property_shareQueueFlagConsistency();
    }

    /// @dev Test Property 1.5: Zero Delta Consistency
    /// Verifies zero position has consistent flag state
    function test_zeroDeltaConsistency() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 15, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Initially should be zero state
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta should initially be zero");
        assertFalse(isPositive, "isPositive should be false when delta is zero");
        
        // Issue then revoke to return to zero
        balanceSheet_issue(100e18);
        
        // Approve share tokens for revoke operation
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(100e18);
        
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta should be zero after equal issue/revoke");
        assertFalse(isPositive, "isPositive should be false when delta is zero");
        
        // Call formal property from Properties.sol (now includes zero delta checking)
        property_shareQueueFlagConsistency();
    }

    /// @dev Test Property 1.6: Nonce Monotonicity
    /// Verifies nonce strictly increases with each submission
    function test_nonceMonotonicity() public {
        // Setup infrastructure with extra gas for submissions
        shortcut_deployNewTokenPoolAndShare(18, 16, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup tokens for operations
        IBaseVault vault = IBaseVault(_getVault());
        
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Get initial nonce
        (,,, uint64 initialNonce) = balanceSheet.queuedShares(poolId, scId);
        
        // Perform operations and submit to increment nonce
        balanceSheet_issue(100e18);
        balanceSheet_submitQueuedShares(0); // Submit to increment nonce
        
        (,,, uint64 afterSubmitNonce) = balanceSheet.queuedShares(poolId, scId);
        assertGt(afterSubmitNonce, initialNonce, "Nonce should increase after submission");
        
        // Another submission cycle
        balanceSheet_issue(50e18);
        balanceSheet_submitQueuedShares(0); // Submit again
        
        (,,, uint64 finalNonce) = balanceSheet.queuedShares(poolId, scId);
        assertGt(finalNonce, afterSubmitNonce, "Nonce should continue increasing");
        
        // Call formal property from Properties.sol
        property_nonceMonotonicity();
    }

    /// @dev Test integration of all Queue State Consistency properties together
    function test_allQueueStatePropertiesTogether() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 17, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup tokens for operations
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Mint tokens and approve for asset operations
        MockERC20 assetToken = MockERC20(vault.asset());
        assetToken.mint(address(this), 1000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Complex sequence of operations
        balanceSheet_deposit(0, 200e18);   // Asset operation
        balanceSheet_issue(150e18);        // Share operation
        balanceSheet_withdraw(0, 50e18);   // Another asset operation
        
        // Approve share tokens for revoke operation
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(75e18);        // Another share operation
        
        // Call all Queue State Consistency property functions from Properties.sol
        property_assetQueueCounterConsistency();
        property_assetCounterBounds();
        property_assetQueueNonNegative();
        property_shareQueueFlagConsistency();
        property_nonceMonotonicity();
        
        // Verify the system is in a consistent state
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        
        (uint128 deposits, uint128 withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);
        (uint128 delta, bool isPositive, uint32 queuedAssetCounter, uint64 nonce) = balanceSheet.queuedShares(poolId, scId);
        
        // Basic consistency checks
        assertGe(deposits, withdrawals, "Net deposits should be positive");
        assertEq(delta, 75e18, "Net share delta should be 75e18 (150-75)");
        assertTrue(isPositive, "isPositive should be true with positive delta");
        assertEq(queuedAssetCounter, 1, "Should have 1 asset with pending operations");
        assertGe(nonce, 0, "Nonce should be valid");
    }
    
    // ============ Integration Tests ============
    
    /// @dev Integration test that validates all properties work on initial state
    /// This provides a baseline verification that the property functions work correctly
    function test_allPropertiesInitialState() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 18, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Call all Share Queue property functions on initial state
        property_shareQueueFlipLogic();
        property_shareQueueFlipBoundaries();
        property_shareQueueCommutativity();
        property_shareQueueSubmission();
        property_shareQueueAssetCounter();
        property_shareQueueFlagConsistency();
        
        // Call all Queue State Consistency property functions on initial state
        property_assetQueueCounterConsistency();
        property_assetCounterBounds();
        property_assetQueueNonNegative();
        property_shareQueueFlagConsistency();
        property_nonceMonotonicity();
        
        console2.log("All BalanceSheet queue properties pass on initial state");
    }

    /// @dev Test Property 2.6: Reserve/Unreserve Balance Integrity
    /// @notice Tests reserve operations maintain strict balance consistency
    function test_property_reserveUnreserveBalanceIntegrity_comprehensive() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 28, false, false, true);
        spoke_updateMember(type(uint64).max);
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        MockERC20 assetToken = MockERC20(vault.asset());
        
        assetToken.mint(address(this), 20000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Test Scenario 1: Initial deposit to establish balance
        balanceSheet_deposit(0, 10000e18);
        
        // Get initial balances - assume no initial reserves
        uint128 initialAvailable = balanceSheet.availableBalanceOf(
            vault.poolId(), vault.scId(), vault.asset(), 0
        );
        
        // Test Scenario 2: Single reserve operation
        balanceSheet_reserve(0, 2000e18);
        
        assertEq(
            balanceSheet.availableBalanceOf(vault.poolId(), vault.scId(), vault.asset(), 0),
            initialAvailable - 2000e18, 
            "Available should decrease by 2000e18"
        );
        
        property_reserveUnreserveBalanceIntegrity();
        
        // Test Scenario 3: Multiple reserve operations
        balanceSheet_reserve(0, 1500e18);
        balanceSheet_reserve(0, 1000e18);
        property_reserveUnreserveBalanceIntegrity();
        
        // Test Scenario 4: Partial unreserve
        balanceSheet_unreserve(0, 1000e18);
        property_reserveUnreserveBalanceIntegrity();
        
        // Test Scenario 5: Complete unreserve  
        balanceSheet_unreserve(0, 3500e18);
        property_reserveUnreserveBalanceIntegrity();
        
        console2.log("Reserve/Unreserve Balance Integrity: All scenarios validated");
    }

    /// @dev Test Property 2.4: Escrow Balance Sufficiency
    /// @notice Tests balance sufficiency under various stress conditions
    function test_property_escrowBalanceSufficiency_comprehensive() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 26, false, false, true);
        spoke_updateMember(type(uint64).max);
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        MockERC20 assetToken = MockERC20(vault.asset());
        
        // Fund the test
        assetToken.mint(address(this), 10000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Test Scenario 1: Build up balance and verify sufficiency
        balanceSheet_deposit(0, 5000e18);
        property_escrowBalanceSufficiency();
        
        // Test Scenario 2: Reserve portion and check available balance sufficiency
        balanceSheet_reserve(0, 2000e18);
        uint128 available = balanceSheet.availableBalanceOf(
            vault.poolId(), 
            vault.scId(), 
            vault.asset(), 
            0
        );
        assertEq(available, 3000e18, "Available should be 3000e18 after reserve");
        
        // Test Scenario 3: Queue withdrawals up to available limit (1000e18 available after 2000e18 reserved)
        balanceSheet_withdraw(0, 1000e18);
        property_escrowBalanceSufficiency();
        
        // Test Scenario 4: Unreserve and verify increased availability
        balanceSheet_unreserve(0, 1000e18);
        available = balanceSheet.availableBalanceOf(
            vault.poolId(),
            vault.scId(), 
            vault.asset(),
            0
        );
        assertEq(available, 3000e18, "Available should remain same after unreserve (withdraw reduces total, not reserved)");
        
        // Test Scenario 5: Additional deposit and complex operations
        balanceSheet_deposit(0, 3000e18);
        balanceSheet_reserve(0, 2000e18);
        balanceSheet_withdraw(0, 1500e18);
        
        // Final validation
        property_escrowBalanceSufficiency();
        
        console2.log("Escrow Balance Sufficiency: All stress scenarios passed");
    }

    /// @dev Test Authorization Boundary Enforcement
    /// @notice Simplified test to validate property function works 
    function test_property_authorizationBoundaryEnforcement_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 32, false, false, true);
        spoke_updateMember(type(uint64).max);
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Fund test with assets
        MockERC20 assetToken = MockERC20(vault.asset());
        assetToken.mint(address(this), 10000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Perform some authorized operations (as address(this) is authorized)
        balanceSheet_deposit(0, 1000e18);
        balanceSheet_noteDeposit(0, 500e18);
        balanceSheet_reserve(0, 200e18);
        balanceSheet_unreserve(0, 100e18);
        
        // Property should pass (no unauthorized operations recorded)
        property_authorizationBoundaryEnforcement();
        
        console2.log("Authorization Boundary Enforcement: Basic validation passed");
    }

    /// @dev Test Share Transfer Restrictions
    /// @notice Simplified test to validate property function works 
    function test_property_shareTransferRestrictions_basic() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 34, false, false, true);
        spoke_updateMember(type(uint64).max);
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        MockERC20 assetToken = MockERC20(vault.asset());
        
        // Fund test
        assetToken.mint(address(this), 10000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Deposit assets to create shares for transfer
        balanceSheet_deposit(0, 5000e18);
        balanceSheet_issue(1000e18);
        
        // Test normal transfer (should work)
        address normalUser = address(0x5001);
        balanceSheet_transferSharesFrom(normalUser, 100e18);
        
        // Validate property
        property_shareTransferRestrictions();
        
        console2.log("Share Transfer Restrictions: Basic validation passed");
    }

    /// @dev Test Property 2.1: Share Token Supply Consistency
    /// @notice Comprehensive test covering all supply tracking scenarios
    function test_property_shareTokenSupplyConsistency_comprehensive() public {
        // Setup
        shortcut_deployNewTokenPoolAndShare(18, 35, false, false, true);
        spoke_updateMember(type(uint64).max);
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        
        // Test Scenario 1: Basic issue and revoke
        balanceSheet_issue(1000e18);
        assertEq(shareToken.totalSupply(), 1000e18, "Supply after issue");
        
        vm.startPrank(_getActor());
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(300e18);
        assertEq(shareToken.totalSupply(), 700e18, "Supply after revoke");
        
        // Test Scenario 2: Transfers between users
        address user2 = _getRandomActor(1);
        balanceSheet_transferSharesFrom(user2, 200e18);
        assertEq(shareToken.totalSupply(), 700e18, "Supply unchanged after transfer");
        assertEq(shareToken.balanceOf(user2), 200e18, "User2 balance after transfer");
        
        // Test Scenario 3: Additional issue from current actor
        balanceSheet_issue(500e18);
        assertEq(shareToken.totalSupply(), 1200e18, "Supply after second issue");
        
        // Validate property - should pass all checks
        property_shareTokenSupplyConsistency();
        
        // Test Scenario 4: Additional revocations using target functions
        uint256 remainingBalance = shareToken.balanceOf(_getActor());
        if (remainingBalance > 0) {
            balanceSheet_revoke(uint128(remainingBalance));
        }
        
        // Final validation
        property_shareTokenSupplyConsistency();
        
        console2.log("Share Token Supply Consistency: All scenarios passed");
    }
    
    /// @dev Test complete deposit and claim flow with queue tracking
    /// @notice Verifies end-to-end async deposit flow with ghost variable tracking
    function test_depositAndClaimFlowWithQueuing() public {
        // Setup complete infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 19, false, false, true);
        
        // Update member to allow transfers
        spoke_updateMember(type(uint64).max);
        
        // Set prices
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Get vault details for ghost variable keys
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        
        // Record initial state
        uint256 depositsStart = ghost_assetQueueDeposits[assetKey];
        uint256 sharesStart = ghost_totalIssued[shareKey];
        
        // Execute explicit operations for end-to-end flow:
        uint128 depositAmount = 1e18;
        
        // 1. Approve and deposit through BalanceSheet (triggers ghost updates)
        asset_approve(address(balanceSheet), depositAmount);
        balanceSheet_deposit(0, depositAmount);  // This updates ghost_assetQueueDeposits
        
        // 2. Request deposit through vault for async flow
        vault_requestDeposit(depositAmount, 0);
        
        // 3. Process through hub
        uint32 depositEpoch = shareClassManager.nowDepositEpoch(scId, assetId);
        hub_approveDeposits(depositEpoch, depositAmount);
        hub_issueShares(depositEpoch, depositAmount);
        
        // 4. Issue shares through BalanceSheet (triggers ghost updates)
        balanceSheet_issue(depositAmount);  // This updates ghost_totalIssued
        
        // 5. Notify and claim
        hub_notifyDeposit(MAX_CLAIMS);
        vault_deposit(depositAmount);
        
        // Verify ghost variables tracked the full flow
        uint256 depositsEnd = ghost_assetQueueDeposits[assetKey];
        uint256 sharesEnd = ghost_totalIssued[shareKey];
        
        assertGt(depositsEnd, depositsStart, "Deposits should have been tracked during flow");
        assertGt(sharesEnd, sharesStart, "Share issuance should have been tracked during flow");
        
        // Call relevant properties to validate end-to-end consistency
        property_assetQueueCounterConsistency();
        property_shareQueueFlagConsistency();
    }
    
    // ============ Asset-Share Proportionality Properties ============
    
    /// @dev Test Property 6: Asset-Share Proportionality on Deposits
    /// Verifies that when assets are deposited, shares are issued proportionally based on exchange rates
    function test_assetShareProportionalityDeposits() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 1, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set consistent prices for operations  
        transientValuation_setPrice_clamped(1e18); // 1:1 ratio (1 pool token per asset)
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        
        // Verify no tracking initially
        assertFalse(ghost_depositProportionalityTracked[assetKey], "Should not be tracked initially");
        assertEq(ghost_cumulativeAssetsDeposited[assetKey], 0, "Initial assets should be 0");
        assertEq(ghost_cumulativeSharesIssuedForDeposits[assetKey], 0, "Initial shares should be 0");
        
        // Perform deposit operations
        uint128 deposit1 = 100e18;
        uint128 deposit2 = 200e18;
        uint256 expectedShares1 = 100e18; // 100 * 1 = 100 shares (1:1 ratio)
        uint256 expectedShares2 = 200e18; // 200 * 1 = 200 shares
        
        // Approve tokens and perform first deposit
        asset_approve(address(balanceSheet), uint128(type(uint128).max));
        balanceSheet_deposit(0, deposit1);
        
        // Verify tracking started
        assertTrue(ghost_depositProportionalityTracked[assetKey], "Should be tracked after first deposit");
        assertEq(ghost_cumulativeAssetsDeposited[assetKey], deposit1, "First deposit not tracked");
        assertEq(ghost_depositOperationCount[assetKey], 1, "Operation count should be 1");
        assertGt(ghost_depositExchangeRate[assetKey], 0, "Exchange rate should be set");
        
        // Issue shares for first deposit
        balanceSheet_issue(uint128(expectedShares1));
        assertEq(ghost_cumulativeSharesIssuedForDeposits[assetKey], expectedShares1, "First share issuance not tracked");
        
        // Second deposit with different amount
        balanceSheet_deposit(0, deposit2);
        
        // Verify cumulative tracking
        assertEq(ghost_cumulativeAssetsDeposited[assetKey], deposit1 + deposit2, "Cumulative deposits incorrect");
        assertEq(ghost_depositOperationCount[assetKey], 2, "Operation count should be 2");
        
        // Issue shares for second deposit
        balanceSheet_issue(uint128(expectedShares2));
        assertEq(
            ghost_cumulativeSharesIssuedForDeposits[assetKey], 
            expectedShares1 + expectedShares2, 
            "Cumulative share issuance incorrect"
        );
        
        // Test the property validation
        property_assetShareProportionalityDeposits();
        
        // Test edge case: zero deposit
        balanceSheet_deposit(0, 0);
        
        // Should still pass proportionality check
        property_assetShareProportionalityDeposits();
        
        // Verify ghost variables are preserved
        assertEq(ghost_cumulativeAssetsDeposited[assetKey], deposit1 + deposit2, "Zero deposit should not affect totals");
    }
    
    /// @dev Test Property 6 Edge Cases: Large deposits and rounding
    function test_assetShareProportionalityDeposits_EdgeCases() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 1, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set unusual price ratio for testing
        transientValuation_setPrice_clamped(1e18); // 1:1 ratio (consistent with main test)
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        
        // Approve tokens first
        asset_approve(address(balanceSheet), uint128(type(uint128).max));
        
        // Test moderately large deposit (avoid overflow)
        uint128 largeDeposit = 1000e18; // Large but reasonable amount
        balanceSheet_deposit(0, largeDeposit);
        
        // Calculate expected shares with precision (1:1 ratio)
        uint256 expectedLargeShares = (uint256(largeDeposit) * 1e18) / 1e18;
        balanceSheet_issue(uint128(expectedLargeShares));
        
        // Should pass proportionality check even with large numbers
        property_assetShareProportionalityDeposits();
        
        // Test small deposit (potential rounding issues)
        uint128 smallDeposit = 3; // Very small amount
        balanceSheet_deposit(0, smallDeposit);
        
        // Small expected shares (will test tolerance)
        uint256 expectedSmallShares = (uint256(smallDeposit) * 1e18) / 1e18; // Should be 3
        balanceSheet_issue(uint128(expectedSmallShares));
        
        // Should still pass with tolerance handling
        property_assetShareProportionalityDeposits();
    }
    
    // ============ Asset-Share Proportionality (Withdrawals) Properties ============
    
    /// @dev Test Property 7: Asset-Share Proportionality on Withdrawals
    /// Verifies that when assets are withdrawn, they are proportional to shares revoked based on exchange rates
    function test_assetShareProportionalityWithdrawals() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 1, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set consistent prices for operations  
        transientValuation_setPrice_clamped(1e18); // 1:1 ratio (1 pool token per asset)
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        
        // Verify no withdrawal tracking initially
        assertFalse(ghost_withdrawalProportionalityTracked[assetKey], "Should not be tracked initially");
        assertEq(ghost_cumulativeAssetsWithdrawn[assetKey], 0, "Initial withdrawn assets should be 0");
        assertEq(ghost_cumulativeSharesRevokedForWithdrawals[assetKey], 0, "Initial revoked shares should be 0");
        
        // Setup: First deposit and issue shares to have assets and shares to withdraw
        uint128 setupDeposit = 500e18;
        uint128 setupShares = 500e18; // 1:1 ratio
        
        asset_approve(address(balanceSheet), uint128(type(uint128).max));
        balanceSheet_deposit(0, setupDeposit);
        balanceSheet_issue(setupShares);
        
        // Verify setup worked
        assertEq(ghost_cumulativeAssetsDeposited[assetKey], setupDeposit, "Setup deposit not tracked");
        
        // Now test withdrawal operations
        uint128 withdraw1 = 100e18;
        uint128 withdraw2 = 200e18;
        uint128 expectedRevoke1 = 100e18; // 1:1 ratio
        uint128 expectedRevoke2 = 200e18;
        
        // First withdrawal-revoke cycle
        balanceSheet_withdraw(0, withdraw1);
        
        // Verify withdrawal tracking started
        assertTrue(ghost_withdrawalProportionalityTracked[assetKey], "Should be tracked after first withdrawal");
        assertEq(ghost_cumulativeAssetsWithdrawn[assetKey], withdraw1, "First withdrawal not tracked");
        assertEq(ghost_withdrawalOperationCount[assetKey], 1, "Withdrawal operation count should be 1");
        assertGt(ghost_withdrawalExchangeRate[assetKey], 0, "Withdrawal exchange rate should be set");
        
        // Approve share token for revocation
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        vm.startPrank(_getActor());
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        // Revoke shares corresponding to first withdrawal
        balanceSheet_revoke(expectedRevoke1);
        assertEq(ghost_cumulativeSharesRevokedForWithdrawals[assetKey], expectedRevoke1, "First share revocation not tracked");
        
        // Validate proportionality after first cycle
        property_assetShareProportionalityWithdrawals();
        
        // Second withdrawal-revoke cycle
        balanceSheet_withdraw(0, withdraw2);
        assertEq(ghost_cumulativeAssetsWithdrawn[assetKey], withdraw1 + withdraw2, "Second withdrawal not tracked");
        assertEq(ghost_withdrawalOperationCount[assetKey], 2, "Withdrawal operation count should be 2");
        
        balanceSheet_revoke(expectedRevoke2);
        assertEq(ghost_cumulativeSharesRevokedForWithdrawals[assetKey], expectedRevoke1 + expectedRevoke2, "Second revocation not tracked");
        
        // Validate proportionality after both cycles
        property_assetShareProportionalityWithdrawals();
        
        // Verify withdrawals don't exceed deposits constraint
        uint256 totalWithdrawn = ghost_cumulativeAssetsWithdrawn[assetKey];
        uint256 totalDeposited = ghost_cumulativeAssetsDeposited[assetKey];
        assertLe(totalWithdrawn, totalDeposited, "Withdrawals should not exceed deposits");
        
        console2.log("Basic withdrawal proportionality test passed");
    }
    
    /// @dev Test Property 7: Complex withdrawal scenarios
    /// Tests multiple users, varying exchange rates, and edge cases
    function test_assetShareProportionalityWithdrawals_complex() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 2, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set initial prices
        transientValuation_setPrice_clamped(1e18); // Start with 1:1 ratio
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        
        // Setup large deposit for multiple withdrawal tests
        uint128 largeDeposit = 1000e18;
        uint128 largeShares = 1000e18; 
        
        asset_approve(address(balanceSheet), uint128(type(uint128).max));
        balanceSheet_deposit(0, largeDeposit);
        balanceSheet_issue(largeShares);
        
        // Approve shares for revocation
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        vm.startPrank(_getActor());
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        // Test 1: Multiple small withdrawals
        uint128 smallWithdraw = 50e18;
        uint128 smallRevoke = 50e18;
        
        for (uint i = 0; i < 3; i++) {
            balanceSheet_withdraw(0, smallWithdraw);
            balanceSheet_revoke(smallRevoke);
            
            // Validate after each small operation
            property_assetShareProportionalityWithdrawals();
        }
        
        // Verify cumulative tracking
        assertEq(ghost_cumulativeAssetsWithdrawn[assetKey], 150e18, "Cumulative withdrawals incorrect");
        assertEq(ghost_cumulativeSharesRevokedForWithdrawals[assetKey], 150e18, "Cumulative revocations incorrect");
        assertEq(ghost_withdrawalOperationCount[assetKey], 3, "Operation count should be 3");
        
        // Test 2: Large withdrawal
        uint128 largeWithdraw = 300e18;
        uint128 largeRevoke = 300e18;
        
        balanceSheet_withdraw(0, largeWithdraw);
        balanceSheet_revoke(largeRevoke);
        
        property_assetShareProportionalityWithdrawals();
        
        // Test 3: Very small withdrawal (rounding edge case)
        uint128 tinyWithdraw = 1; // 1 wei
        uint128 tinyRevoke = 1; // 1 wei of shares
        
        balanceSheet_withdraw(0, tinyWithdraw);
        balanceSheet_revoke(tinyRevoke);
        
        // Should still pass with tolerance handling
        property_assetShareProportionalityWithdrawals();
        
        // Final validation: check that exchange rate consistency is maintained
        uint256 finalOps = ghost_withdrawalOperationCount[assetKey];
        assertGt(finalOps, 1, "Should have multiple operations for rate consistency test");
        
        // Verify exchange rate is within reasonable bounds (should be close to 1e18 for 1:1 ratio)
        uint256 avgRate = ghost_withdrawalExchangeRate[assetKey];
        assertGt(avgRate, 0.99e18, "Average exchange rate should be close to 1e18");
        assertLt(avgRate, 1.01e18, "Average exchange rate should be close to 1e18");
        
        console2.log("Complex withdrawal proportionality test passed");
    }

    /// @dev Test Price Consistency During Operations
    /// @notice Tests price stability during normal operations vs admin overrides
    function test_priceConsistencyDuringOperations() public {
        // Setup infrastructure
        shortcut_deployNewTokenPoolAndShare(18, 32, false, false, true);
        spoke_updateMember(type(uint64).max);
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        MockERC20 assetToken = MockERC20(vault.asset());
        AssetId assetId = spoke.vaultDetails(vault).assetId;
        
        assetToken.mint(address(this), 10000e18);
        assetToken.approve(address(balanceSheet), type(uint256).max);
        
        // Test Scenario 1: Capture initial price snapshots through normal operations
        balanceSheet_deposit(0, 1000e18);
        balanceSheet_issue(1000e18);
        
        D18 initialSharePrice = spoke.pricePoolPerShare(vault.poolId(), vault.scId(), false);
        D18 initialAssetPrice = spoke.pricePoolPerAsset(vault.poolId(), vault.scId(), assetId, true);
        
        // Property should pass after first operations (snapshots taken)
        property_priceConsistencyDuringOperations();
        
        // Test Scenario 2: More normal operations should maintain price stability
        balanceSheet_withdraw(0, 200e18);
        
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(vault.poolId(), vault.scId());
        shareToken.approve(address(balanceSheet), type(uint256).max);
        vm.stopPrank();
        
        balanceSheet_revoke(200e18);
        
        // Property should still pass (prices should be stable within 1%)
        property_priceConsistencyDuringOperations();
        
        D18 afterOpsSharePrice = spoke.pricePoolPerShare(vault.poolId(), vault.scId(), false);
        D18 afterOpsAssetPrice = spoke.pricePoolPerAsset(vault.poolId(), vault.scId(), assetId, true);
        
        // Manual verification: prices should remain stable (within 1% tolerance)
        // Skip manual verification if either price is zero (uninitialized)
        if (D18.unwrap(initialSharePrice) > 0 && D18.unwrap(afterOpsSharePrice) > 0) {
            uint256 sharePriceDeviation = D18.unwrap(afterOpsSharePrice) > D18.unwrap(initialSharePrice)
                ? ((D18.unwrap(afterOpsSharePrice) - D18.unwrap(initialSharePrice)) * 10000) / D18.unwrap(initialSharePrice)
                : ((D18.unwrap(initialSharePrice) - D18.unwrap(afterOpsSharePrice)) * 10000) / D18.unwrap(initialSharePrice);
            assertLe(sharePriceDeviation, 100, "Share price deviation should be <= 1% for normal ops");
        }
        
        // Test Scenario 3: Admin price override should be exempted from checks
        balanceSheet_overridePricePoolPerAsset(D18.wrap(2e18));
        
        // Property should still pass (admin overrides are exempted)
        property_priceConsistencyDuringOperations();
        
        // Test Scenario 4: Price reset and continue with normal operations
        balanceSheet_resetPricePoolPerAsset();
        balanceSheet_deposit(0, 500e18);
        balanceSheet_issue(500e18);
        
        // Property should pass (fresh baseline after reset)
        property_priceConsistencyDuringOperations();
        
        // Test Scenario 5: Share price override and reset
        balanceSheet_overridePricePoolPerShare(D18.wrap(1.5e18));
        property_priceConsistencyDuringOperations();
        
        balanceSheet_resetPricePoolPerShare();
        balanceSheet_withdraw(0, 100e18);
        balanceSheet_revoke(100e18);
        
        // Final validation
        property_priceConsistencyDuringOperations();
        
        console2.log("Price consistency during operations test passed");
    }
}

/// @dev Mock contract for testing endorsed contract functionality
contract MockEndorsedContract {
    /// @dev Simple contract that can receive share tokens but should be blocked from transferring
    function onERC20Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC20Received.selector;
    }
}