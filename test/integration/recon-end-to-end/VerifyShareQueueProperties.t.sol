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

import {TargetFunctions} from "./TargetFunctions.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

/// @title VerifyShareQueueProperties
/// @notice Verification test for ShareQueueProperties - tests share queue flip logic with real operations
contract VerifyShareQueueProperties is Test, TargetFunctions, FoundryAsserts {

    function setUp() public {
        setup();
    }
    
    /// @notice Test the core share queue flip logic with real BalanceSheet operations
    function test_shareQueueFlipLogic() public {
        console2.log("=== Testing Share Queue Flip Logic with Real Operations ===");
        
        // Setup complete infrastructure using shortcut
        shortcut_deployNewTokenPoolAndShare(18, 1, false, false, true);
        
        // Enable transfers for test contract
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Get pool and share class details
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        console2.log("Testing with poolId:", uint64(PoolId.unwrap(poolId)));
        console2.log("ShareClassId found, proceeding with tests");
        
        // Test initial state (should be zero delta, isPositive false)
        (uint128 delta, bool isPositive, uint32 counter, uint64 nonce) = 
            balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Initial delta should be 0");
        assertFalse(isPositive, "Initial isPositive should be false");
        
        // Test sequence 1: Issue 100 shares (should go positive)
        console2.log("--- Issuing 100 shares ---");
        balanceSheet_issue(100);
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 100, "Delta after issue should be 100");
        assertTrue(isPositive, "Should be positive after issue");
        
        // Test sequence 2: Issue additional shares to enable larger revoke test
        console2.log("--- Issuing additional 300 shares to enable flip testing ---");
        balanceSheet_issue(300);  // Total issued = 400
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 400, "Delta after second issue should be 400");
        assertTrue(isPositive, "Should remain positive after second issue");
        
        // Now revoke 200 shares (should remain positive 200)
        console2.log("--- Revoking 200 shares ---");
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), 200);
        vm.stopPrank();
        
        balanceSheet_revoke(200);
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 200, "Delta after revoke should be 200 (400-200)");
        assertTrue(isPositive, "Should remain positive (400-200 = +200)");
        
        // Check actor's token balance after revoke
        uint256 actorBalance = shareToken.balanceOf(_getActor());
        console2.log("Actor's ShareToken balance after revoking 200:", actorBalance);
        
        // Test sequence 3: Revoke additional 200 shares (net +0, then revoke more to go negative)
        console2.log("--- Revoking additional 200 shares (should go to zero) ---");
        vm.startPrank(_getActor());
        shareToken.approve(address(balanceSheet), 200);
        vm.stopPrank();
        
        balanceSheet_revoke(200);  // Total revoked = 400, issued = 400, net = 0
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta after exact cancellation should be 0");
        assertFalse(isPositive, "Should be false when delta is 0");
        
        // Test sequence 4: Issue 50 shares (should go to positive 50)
        console2.log("--- Issuing 50 shares (should go positive) ---");
        balanceSheet_issue(50);
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 50, "Delta should be 50 after issuing from zero");
        assertTrue(isPositive, "Should be true when delta is positive");
        
        console2.log("--- Verifying all share queue properties ---");
        
        // Now verify basic share queue properties work correctly with this state
        _verifyShareQueueFlipLogic(poolId, scId);
        _verifyShareQueueCommutativity(poolId, scId);
        
    }
    
    /// @notice Test boundary conditions and edge cases
    function test_shareQueueBoundaryConditions() public {
        console2.log("=== Testing Share Queue Boundary Conditions ===");
        
        // Setup
        shortcut_deployNewTokenPoolAndShare(18, 2, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        // Test 1: Operation exactly equal to delta (should cancel to zero)
        console2.log("--- Testing exact cancellation ---");
        balanceSheet_issue(100);
        
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), 100);
        vm.stopPrank();
        
        balanceSheet_revoke(100); // Exactly equal
        
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta should be 0 after exact cancellation");
        assertFalse(isPositive, "isPositive should be false when delta is 0");
        
        // Test 2: Multiple small operations (ensure we have enough tokens to revoke)
        console2.log("--- Testing multiple small operations ---");
        
        // Issue some tokens first to enable revocations
        balanceSheet_issue(200);
        console2.log("  Pre-issued 200 tokens for revoke testing");
        
        for (uint256 i = 1; i <= 5; i++) {
            uint128 amount = uint128(i * 10);
            if (i % 2 == 0) {
                // Even: revoke (we have enough shares now)
                vm.startPrank(_getActor());
                shareToken.approve(address(balanceSheet), amount);
                vm.stopPrank();
                balanceSheet_revoke(amount);
                console2.log("  Revoked:", amount);
            } else {
                // Odd: issue
                balanceSheet_issue(amount);
                console2.log("  Issued:", amount);
            }
        }
        
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        console2.log("Final state after multiple operations - delta:", delta, "isPositive:", isPositive);
        
        // Verify properties still hold
        _verifyShareQueueFlipLogic(poolId, scId);
        _verifyShareQueueCommutativity(poolId, scId);
        
    }
    
    /// @notice Test ghost variable tracking accuracy
    function test_ghostVariableAccuracy() public {
        console2.log("=== Testing Ghost Variable Tracking Accuracy ===");
        
        // Setup
        shortcut_deployNewTokenPoolAndShare(18, 3, false, false, true);
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));
        
        // Track operations manually
        uint256 totalIssued = 0;
        uint256 totalRevoked = 0;
        int256 expectedNet = 0;
        
        console2.log("--- Executing tracked operations ---");
        
        // Operation 1: Issue 200
        balanceSheet_issue(200);
        totalIssued += 200;
        expectedNet += 200;
        
        assertEq(ghost_totalIssued[shareKey], totalIssued, "Ghost totalIssued should match");
        assertEq(ghost_netSharePosition[shareKey], expectedNet, "Ghost net position should match");
        
        // Operation 2: Revoke 80
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), 80);
        vm.stopPrank();
        
        balanceSheet_revoke(80);
        totalRevoked += 80;
        expectedNet -= 80;
        
        assertEq(ghost_totalRevoked[shareKey], totalRevoked, "Ghost totalRevoked should match");
        assertEq(ghost_netSharePosition[shareKey], expectedNet, "Ghost net position should match");
        
        // Operation 3: Issue 30 (should be net positive)
        balanceSheet_issue(30);
        totalIssued += 30;
        expectedNet += 30;
        
        assertEq(ghost_totalIssued[shareKey], totalIssued, "Ghost totalIssued should match");
        assertEq(ghost_netSharePosition[shareKey], expectedNet, "Ghost net position should match");
        
        // Verify commutativity property
        _verifyShareQueueCommutativity(poolId, scId);
        
        console2.log("Final totals - Issued:", totalIssued, "Revoked:", totalRevoked);
        console2.log("Expected net position:", uint256(expectedNet >= 0 ? expectedNet : -expectedNet), expectedNet >= 0 ? "(positive)" : "(negative)");
    }
    
    // Helper property verification functions
    
    /// @notice Verify basic share queue flip logic for a specific pool/share class
    function _verifyShareQueueFlipLogic(PoolId poolId, ShareClassId scId) internal view {
        bytes32 key = keccak256(abi.encode(poolId, scId));
        
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        
        // Calculate expected net position from ghost tracking
        int256 expectedNet = ghost_netSharePosition[key];
        
        // Calculate actual net position from queue state
        int256 actualNet = isPositive ? int256(uint256(delta)) : -int256(uint256(delta));
        
        // For zero delta, must be negative (isPositive = false)
        if (delta == 0) {
            assertFalse(isPositive, "SHARE-QUEUE-01: Zero delta must have isPositive = false");
            assertEq(actualNet, 0, "SHARE-QUEUE-02: Zero delta must represent zero net position");
        } else {
            // Non-zero delta: verify sign consistency
            assertTrue(
                (isPositive && actualNet > 0) || (!isPositive && actualNet < 0),
                "SHARE-QUEUE-03: isPositive flag must match delta sign"
            );
        }
        
        // Verify net position matches tracked operations
        assertEq(actualNet, expectedNet, "SHARE-QUEUE-04: Net position must match tracked issue/revoke operations");
    }
    
    /// @notice Verify commutativity property for a specific pool/share class
    function _verifyShareQueueCommutativity(PoolId poolId, ShareClassId scId) internal view {
        bytes32 key = keccak256(abi.encode(poolId, scId));
        
        // Net position should equal total issued minus total revoked
        int256 expectedFromTotals = int256(ghost_totalIssued[key]) - int256(ghost_totalRevoked[key]);
        int256 trackedNet = ghost_netSharePosition[key];
        
        assertEq(
            expectedFromTotals, 
            trackedNet, 
            "SHARE-QUEUE-06: Net position must be commutative (issued - revoked)"
        );
    }

    /// @notice Test that before-state ghost variables are properly captured and asserted
    function test_beforeStateCapture() public {
        console2.log("=== Testing Before-State Capture and Assertions ===");
        
        // Deploy complete infrastructure with unique salt
        shortcut_deployNewTokenPoolAndShare(18, 4, false, false, true);
        
        // Enable transfers for test contract
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Get vault reference
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        bytes32 shareKey = _poolShareKey(poolId, scId);
        
        // Initial state should be zero
        (uint128 initialDelta, bool initialIsPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(initialDelta, 0, "Initial delta should be 0");
        assertFalse(initialIsPositive, "Initial isPositive should be false");
        
        // Phase 1: Create non-zero state for before-capture testing
        console2.log("--- Phase 1: Setting up non-zero state ---");
        balanceSheet_issue(150);
        
        // Verify state is now non-zero
        (uint128 currentDelta, bool currentIsPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(currentDelta, 150, "Current delta should be 150");
        assertTrue(currentIsPositive, "Current isPositive should be true");
        console2.log("Non-zero state established: delta=150, isPositive=true");
        
        // Phase 2: Perform operation that triggers before-state capture
        console2.log("--- Phase 2: Testing before-state capture during operation ---");
        
        // The next operation should capture the current state as "before" state
        balanceSheet_issue(50); // This will trigger _captureShareQueueState in __before()
        
        // Verify the before-state was captured correctly
        // The before-state should have been delta=150, isPositive=true
        assertEq(before_shareQueueDelta[shareKey], 150, "Before delta should be 150");
        assertTrue(before_shareQueueIsPositive[shareKey], "Before isPositive should be true");
        
        // Verify current state changed correctly
        (currentDelta, currentIsPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(currentDelta, 200, "Current delta should be 200 after second issue");
        assertTrue(currentIsPositive, "Current isPositive should remain true");
        
        // Phase 3: Test before-state capture with revoke operation
        console2.log("--- Phase 3: Testing before-state capture with revoke ---");
        
        // Set up ShareToken approval for revoke
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), 100);
        vm.stopPrank();
        
        // Perform revoke - this should capture current state (delta=200, isPositive=true) as before
        balanceSheet_revoke(100);
        
        // Verify before-state was updated to previous state
        assertEq(before_shareQueueDelta[shareKey], 200, "Before delta should be 200 from previous state");
        assertTrue(before_shareQueueIsPositive[shareKey], "Before isPositive should be true from previous state");
        
        // Verify current state after revoke
        (currentDelta, currentIsPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(currentDelta, 100, "Current delta should be 100 after revoke");
        assertTrue(currentIsPositive, "Current isPositive should remain true");
        
    }

    /// @notice Test nonce increment tracking and before-state capture  
    function test_nonceIncrement() public {
        console2.log("=== Testing Nonce Increment and Before-State Tracking ===");
        
        // Deploy complete infrastructure with unique salt
        shortcut_deployNewTokenPoolAndShare(18, 5, false, false, true);
        
        // Enable transfers for test contract
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        bytes32 shareKey = _poolShareKey(poolId, scId);
        
        // Get initial nonce
        (,,, uint64 initialNonce) = balanceSheet.queuedShares(poolId, scId);
        console2.log("Initial nonce:", initialNonce);
        
        // Create some queue state to submit
        balanceSheet_issue(100);
        (uint128 delta, bool isPositive,, uint64 nonceBeforeSubmit) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 100, "Delta should be 100 before submit");
        assertTrue(isPositive, "Should be positive before submit");
        console2.log("Queue state before submit: delta=100, isPositive=true, nonce=", nonceBeforeSubmit);
        
        // Submit queue shares - this should increment the nonce
        console2.log("--- Submitting queue shares to increment nonce ---");
        balanceSheet_submitQueuedShares(0);
        
        // Check that nonce incremented and before-state was captured
        (,,, uint64 nonceAfterSubmit) = balanceSheet.queuedShares(poolId, scId);
        
        // Assert that nonce MUST increment after submitQueuedShares
        assertGt(nonceAfterSubmit, nonceBeforeSubmit, "Nonce must increment after submitQueuedShares");
        
        // Verify before_nonce was captured correctly
        assertEq(before_nonce[shareKey], nonceBeforeSubmit, "Before nonce should match pre-submit nonce");
        
    }

    /// @notice Test asset counter tracking in before-state
    function test_assetCounterTracking() public {
        console2.log("=== Testing Asset Counter Before-State Tracking ===");
        
        // Deploy complete infrastructure with unique salt
        shortcut_deployNewTokenPoolAndShare(18, 6, false, false, true);
        
        // Enable transfers for test contract
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        bytes32 shareKey = _poolShareKey(poolId, scId);
        
        // Get initial asset counter
        (,, uint32 initialCounter,) = balanceSheet.queuedShares(poolId, scId);
        console2.log("Initial asset counter:", initialCounter);
        
        // Mint tokens to test contract before attempting deposits
        MockERC20 assetToken = MockERC20(vault.asset());
        assetToken.mint(address(this), 1000);
        console2.log("Minted 1000 tokens to test contract for deposits");
        console2.log("Test contract token balance:", assetToken.balanceOf(address(this)));
        
        // Approve BalanceSheet to transfer tokens on behalf of test contract
        assetToken.approve(address(balanceSheet), type(uint256).max);
        console2.log("Approved BalanceSheet for token transfers");
        
        // Add deposits to create asset queue activity
        console2.log("--- Adding deposits to create asset queue activity ---");
        balanceSheet_deposit(0, 50); // tokenId=0, amount=50
        
        // Check if counter changed and verify before-state capture
        (,, uint32 counterAfterDeposit,) = balanceSheet.queuedShares(poolId, scId);
        
        // Perform another operation to trigger before-state capture
        balanceSheet_deposit(0, 25);
        
        // Verify before-state captured the previous counter value
        assertEq(before_queuedAssetCounter[shareKey], counterAfterDeposit, "Before asset counter should match previous state");
        
        // Verify current counter
        (,, uint32 currentCounter,) = balanceSheet.queuedShares(poolId, scId);
        console2.log("Current asset counter:", currentCounter);
        
    }

    /// @notice Test flip detection using before-state variables
    function test_flipDetectionWithBeforeState() public {
        console2.log("=== Testing Flip Detection with Before-State Variables ===");
        
        // Deploy complete infrastructure with unique salt
        shortcut_deployNewTokenPoolAndShare(18, 7, false, false, true);
        
        // Enable transfers for test contract
        spoke_updateMember(type(uint64).max);
        
        // Set prices for operations
        transientValuation_setPrice_clamped(1e18);
        hub_notifyAssetPrice();
        hub_notifySharePrice_clamped();
        
        // Setup
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        
        bytes32 shareKey = _poolShareKey(poolId, scId);
        
        // Phase 1: Create positive state
        console2.log("--- Phase 1: Creating positive queue state ---");
        balanceSheet_issue(100);
        (uint128 delta, bool isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 100, "Delta should be 100");
        assertTrue(isPositive, "Should be positive");
        console2.log("Positive state created: delta=100, isPositive=true");
        
        // Phase 2: Perform operation that should flip to negative
        console2.log("--- Phase 2: Attempting flip to negative ---");
        
        // Issue more shares to get enough tokens for large revoke
        balanceSheet_issue(50); // Total issued = 150, actor has 150 tokens
        
        // Set up approval for large revoke
        vm.startPrank(_getActor());
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        shareToken.approve(address(balanceSheet), 150);
        vm.stopPrank();
        
        // Revoke all shares to go to zero
        balanceSheet_revoke(150); // Net should be 0
        (delta, isPositive,,) = balanceSheet.queuedShares(poolId, scId);
        assertEq(delta, 0, "Delta should be 0 after exact cancellation");
        assertFalse(isPositive, "Should be false when delta is 0");
        
        // Verify before-state captured the positive state
        assertGt(before_shareQueueDelta[shareKey], 0, "Before delta should be > 0 (from positive state)");
        assertTrue(before_shareQueueIsPositive[shareKey], "Before isPositive should be true");
        
        // Phase 3: Test property_shareQueueFlipBoundaries with actual before/after data
        console2.log("--- Phase 3: Testing flip boundary property ---");
        
        // Manually call the flip boundaries property to test with our before-state
        uint128 deltaBefore = before_shareQueueDelta[shareKey];
        bool isPositiveBefore = before_shareQueueIsPositive[shareKey];
        (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(poolId, scId);
        
        // Assert that a flip occurred from positive to neutral (isPositive=false with delta=0)
        bool flipOccurred = (isPositiveBefore != isPositiveAfter) && (deltaBefore != 0 || deltaAfter != 0);
        
        // This test scenario explicitly creates a flip from positive to neutral state
        assertTrue(flipOccurred, "Expected flip from positive to neutral state should occur");
        assertTrue(isPositiveBefore, "Before state should be positive"); 
        assertFalse(isPositiveAfter, "After state should be neutral (isPositive=false)");
        assertGt(deltaBefore, 0, "Before delta should be > 0");
        assertEq(deltaAfter, 0, "After delta should be 0 (neutral state)");
        
    }
}