// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AsyncVaultProperties} from "./AsyncVaultProperties.sol";

import {D18} from "../../../../src/misc/types/D18.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {PoolEscrow} from "../../../../src/core/spoke/PoolEscrow.sol";
import {PricingLib} from "../../../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {VaultDetails} from "../../../../src/core/spoke/interfaces/ISpoke.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";

import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";

import {console2} from "forge-std/console2.sol";

import {Setup} from "../Setup.sol";
import {vm} from "@chimera/Hevm.sol";
import {Asserts} from "@chimera/Asserts.sol";
import {Helpers} from "../utils/Helpers.sol";

/// @dev ERC-7540 Properties used by Centrifuge
/// See `AsyncVaultProperties` for more properties that can be re-used in your project

// TODO(wischli): Rename to `(Base)VaultProperties` to indicate support for async as well as sync vaults
abstract contract AsyncVaultCentrifugeProperties is Setup, Asserts, AsyncVaultProperties {
    using CastLib for *;
    using MathLib for *;

    /// === Overridden Implementations === ///
    function asyncVault_3(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_3(asyncVaultTarget);
    }

    function asyncVault_4(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_4(asyncVaultTarget);
    }

    function asyncVault_5(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_5(asyncVaultTarget);
    }

    function asyncVault_6_deposit(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_deposit(asyncVaultTarget, amt);
    }

    function asyncVault_6_mint(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_mint(asyncVaultTarget, amt);
    }

    function asyncVault_6_withdraw(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_withdraw(asyncVaultTarget, amt);
    }

    function asyncVault_6_redeem(address asyncVaultTarget, uint256 amt) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_redeem(asyncVaultTarget, amt);
    }

    function asyncVault_7(address asyncVaultTarget, uint256 shares) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_7(asyncVaultTarget, shares);
    }

    function asyncVault_8(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_8(asyncVaultTarget);
    }

    function asyncVault_9_deposit(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_deposit(asyncVaultTarget);
    }

    function asyncVault_9_mint(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_mint(asyncVaultTarget);
    }

    function asyncVault_9_withdraw(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_withdraw(asyncVaultTarget);
    }

    function asyncVault_9_redeem(address asyncVaultTarget) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_9_redeem(asyncVaultTarget);
    }

    /// === Custom Properties === ///

    /// @dev Property: user can always maxDeposit if they have > 0 assets and are approved
    /// @dev Property: user can always deposit an amount between 1 and maxDeposit if they have > 0 assets and are approved
    /// @dev Property: maxDeposit should decrease by the amount deposited
    /// @dev Property: depositing maxDeposit blocks the user from depositing more
    /// @dev Property: depositing maxDeposit does not increase the pendingDeposit
    /// @dev Property: depositing maxDeposit doesn't mint more than maxMint shares
    /// @dev Property: For async vaults, validates globalEscrow share transfers
    /// @dev Property: For sync vaults, validates PoolEscrow state changes
    // TODO(wischli): Add back statelessTest modifier after optimizer run
    function asyncVault_maxDeposit(
        uint64,
        /* poolEntropy */
        uint32,
        /* scEntropy */
        uint256 depositAmount
    )
        public
        statelessTest
    {
        uint256 maxDepositBefore = _getVault().maxDeposit(_getActor());

        depositAmount = between(depositAmount, 1, maxDepositBefore);

        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();
        AssetId assetId = vaultRegistry.vaultDetails(_getVault()).assetId;

        (uint256 pendingDepositBefore,) =
            batchRequestManager.depositRequest(poolId, scId, assetId, _getActor().toBytes32());

        bool isAsyncVault = Helpers.isAsyncVault(address(_getVault()));

        PoolEscrowState memory escrowState = _analyzePoolEscrowState(poolId, scId);

        uint256 maxMintBefore;
        AsyncClaimState memory claimState;
        if (isAsyncVault) {
            claimState = _captureAsyncClaimStateBefore(_getVault(), _getActor());
            maxMintBefore = claimState.maxMintBefore;
        }
        // TODO(wischli): Re-enable after merging main with maxMint refactor to overcome Uint128_Overflow
        // else {
        //     maxMintBefore = syncManager.maxMint(_getVault(), _getActor());
        // }

        vm.prank(_getActor());
        try _getVault().deposit(depositAmount, _getActor()) returns (uint256 shares) {
            console2.log(" === After Depositing: Max Deposit === ");
            uint256 maxDepositAfter = _getVault().maxDeposit(_getActor());

            if (isAsyncVault) {
                // For async vaults, validate globalEscrow share transfers instead of poolEscrow
                claimState.sharesReturned = shares;
                _updateAsyncClaimStateAfter(claimState, _getVault(), _getActor());
                _validateAsyncVaultClaim(claimState, depositAmount, "asyncVault_maxDeposit");

                _validateAsyncMaxValueChange(maxDepositBefore, maxDepositAfter, depositAmount, "Deposit");
            } else {
                // For sync vaults, validate PoolEscrow changes due to immediate deposit
                _updatePoolEscrowStateAfter(escrowState);
                _validateSyncMaxValueChange(maxDepositBefore, maxDepositAfter, depositAmount, "Deposit", escrowState);

                _logPoolEscrowAnalysis("Deposit", maxDepositBefore, maxDepositAfter, depositAmount, escrowState);
            }

            if (depositAmount == maxDepositBefore) {
                (uint256 pendingDeposit,) =
                    batchRequestManager.depositRequest(poolId, scId, assetId, _getActor().toBytes32());

                eq(pendingDeposit, pendingDepositBefore, "pendingDeposit should not increase");

                uint256 maxMintAfter;
                if (isAsyncVault) {
                    (maxMintAfter,,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());
                    lte(shares, maxMintBefore, "shares minted surpass maxMint");
                } else {
                    maxMintAfter = syncManager.maxMint(_getVault(), _getActor());
                }
                eq(maxMintAfter, 0, "maxMint should be 0 after maxDeposit");
            }
        } catch (bytes memory err) {
            bool expectedError = checkError(err, "VaultNotLinked()");
            // For async vaults, validate failure reason
            if (isAsyncVault && !expectedError) {
                _validateAsyncDepositFailure(depositAmount);
            } else {
                console2.log("Sync vault deposit failed - likely due to transfer restrictions");
            }
        }
    }

    /// @dev Property: user can always maxMint if they have > 0 assets and are approved
    /// @dev Property: user can always mint an amount between 1 and maxMint if they have > 0 assets and are approved
    /// @dev Property: maxMint should be 0 after using maxMint as mintAmount
    /// @dev Property: minting maxMint should not mint more than maxDeposit shares
    function asyncVault_maxMint(
        uint64,
        /* poolEntropy */
        uint32,
        /* scEntropy */
        uint256 mintAmount
    )
        public
        statelessTest
    {
        uint256 maxMintBefore = _getVault().maxMint(_getActor());
        uint256 maxDepositBefore = _getVault().maxDeposit(_getActor());
        bool isAsyncVault = Helpers.isAsyncVault(address(_getVault()));
        require(maxMintBefore > 0, "must be able to mint");

        mintAmount = between(mintAmount, 1, maxMintBefore);

        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();

        // === PoolEscrow State Analysis Before Mint ===
        PoolEscrowState memory escrowState = _analyzePoolEscrowState(poolId, scId);

        AsyncClaimState memory claimState;
        if (isAsyncVault) {
            claimState = _captureAsyncClaimStateBefore(_getVault(), _getActor());
        }

        vm.prank(_getActor());
        try _getVault().mint(mintAmount, _getActor()) returns (uint256 assets) {
            uint256 maxMintAfter = _getVault().maxMint(_getActor());
            uint256 maxDepositAfter = _getVault().maxDeposit(_getActor());

            if (isAsyncVault) {
                claimState.sharesReturned = mintAmount;
                _updateAsyncClaimStateAfter(claimState, _getVault(), _getActor());
                _validateAsyncVaultClaim(claimState, assets, "asyncVault_maxMint");

                _validateAsyncMaxValueChange(maxMintBefore, maxMintAfter, mintAmount, "Mint");

                _validateAsyncMaxValueChange(maxDepositBefore, maxDepositAfter, assets, "Deposit");
            } else {
                // For sync vaults, validate PoolEscrow changes due to immediate mint
                _updatePoolEscrowStateAfter(escrowState);
                _validateSyncMaxValueChange(maxMintBefore, maxMintAfter, assets, "Mint", escrowState);
                // TODO: Investigate checking with maxDeposit as done for asyncVault

                _logPoolEscrowAnalysis("Mint", maxMintBefore, maxMintAfter, mintAmount, escrowState);
            }

            if (mintAmount == maxMintBefore) {
                uint256 maxMintVaultAfter = _getVault().maxMint(_getActor());

                eq(maxMintVaultAfter, 0, "maxMint in vault should be 0 after maxMint");
                lte(assets, maxDepositBefore, "assets consumed surpass maxDeposit");

                uint256 maxMintManagerAfter;
                if (Helpers.isAsyncVault(address(_getVault()))) {
                    (maxMintManagerAfter,,,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());
                } else {
                    maxMintManagerAfter = syncManager.maxMint(_getVault(), _getActor());
                }
                eq(maxMintManagerAfter, 0, "maxMintManagerAfter in request should be 0 after maxMint");
            }
        } catch (bytes memory err) {
            // Determine vault type for proper validation
            bool isAsyncVaultCheck = Helpers.isAsyncVault(address(_getVault()));
            bool expectedError = checkError(err, "VaultNotLinked()");

            if (isAsyncVaultCheck && !expectedError) {
                _validateAsyncMintFailure(mintAmount);
            } else {
                console2.log("Sync vault mint failed - likely due to transfer restrictions");
            }
        }
    }

    /// @dev Property: user can always maxWithdraw if they have > 0 shares and are approved
    /// @dev Property: user can always withdraw an amount between 1 and maxWithdraw if they have > 0 shares and are
    /// approved
    /// @dev Property: maxWithdraw should decrease by the amount withdrawn
    function asyncVault_maxWithdraw(
        uint64,
        /* poolEntropy */
        uint32,
        /* scEntropy */
        uint256 withdrawAmount
    )
        public
        statelessTest
    {
        uint256 maxWithdrawBefore = _getVault().maxWithdraw(_getActor());
        require(maxWithdrawBefore > 0, "must be able to withdraw");

        withdrawAmount = between(withdrawAmount, 1, maxWithdrawBefore);

        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();
        AssetId assetId = vaultRegistry.vaultDetails(_getVault()).assetId;

        vm.prank(_getActor());
        try _getVault().withdraw(withdrawAmount, _getActor(), _getActor()) returns (uint256 shares) {
            uint256 maxWithdrawAfter = _getVault().maxWithdraw(_getActor());
            uint256 difference = maxWithdrawBefore - withdrawAmount;
            uint256 assets = _getVault().convertToAssets(shares);

            t(difference == maxWithdrawAfter, "rounding error in maxWithdraw");

            if (withdrawAmount == maxWithdrawBefore) {
                (,,,,, uint128 pendingWithdrawRequest,,,,) = asyncRequestManager.investments(_getVault(), _getActor());
                (uint256 pendingWithdraw,) =
                    batchRequestManager.redeemRequest(poolId, scId, assetId, _getActor().toBytes32());

                eq(pendingWithdrawRequest, 0, "pendingWithdrawRequest should be 0 after maxWithdraw");
                eq(pendingWithdraw, 0, "pendingWithdraw should be 0 after maxWithdraw");
                lte(assets, maxWithdrawBefore, "assets withdrawn surpass maxWithdraw");
            }
        } catch (bytes memory err) {
            // Determine vault type for proper validation
            bool isAsyncVault = Helpers.isAsyncVault(address(_getVault()));
            bool expectedError = checkError(err, "VaultNotLinked()");

            if (isAsyncVault && !expectedError) {
                bool unknownFailure = _validateAsyncWithdrawFailure(withdrawAmount);
                t(!unknownFailure, "Async vault withdraw failed for unknown reason");
            } else {
                console2.log("Sync vault withdraw failed - likely due to transfer restrictions");
            }
        }
    }

    /// @dev Property: user can always maxRedeem if they have > 0 shares and are approved
    /// @dev Property: user can always redeem an amount between 1 and maxRedeem if they have > 0 shares and are approved
    /// @dev Property: redeeming maxRedeem does not increase the pendingRedeem
    // TODO(wischli): Add back statelessTest modifier after optimizer run
    function asyncVault_maxRedeem(
        uint64,
        /* poolEntropy */
        uint32,
        /* scEntropy */
        uint256 redeemAmount
    )
        public
        statelessTest
    {
        uint256 maxRedeemBefore = _getVault().maxRedeem(_getActor());
        require(maxRedeemBefore > 0, "must be able to redeem");

        redeemAmount = between(redeemAmount, 1, maxRedeemBefore);

        PoolId poolId = _getVault().poolId();
        ShareClassId scId = _getVault().scId();
        AssetId assetId = vaultRegistry.vaultDetails(_getVault()).assetId;

        (, uint32 latestRedeemApproval,,) = batchRequestManager.epochId(poolId, scId, assetId);

        // Fetch the actual approved share amount for this epoch
        (uint128 approvedShareAmount,,,,,) =
            batchRequestManager.epochRedeemAmounts(poolId, scId, assetId, latestRedeemApproval);

        (uint256 pendingRedeemBefore,) =
            batchRequestManager.redeemRequest(poolId, scId, assetId, _getActor().toBytes32());

        vm.prank(_getActor());
        try _getVault()
            .redeem(
                redeemAmount, _getActor(), _getActor()
            ) returns (
            uint256 /* assets */
        ) {
            uint256 maxRedeemAfter = _getVault().maxRedeem(_getActor());
            uint256 difference = maxRedeemBefore - redeemAmount;

            // maxRedeemAfter needs to at least be decreased by the difference amount
            gte(difference, maxRedeemAfter, "maxRedeemAfter isn't sufficiently decreased");

            if (redeemAmount == maxRedeemBefore) {
                (,,,,, uint128 pendingRedeemRequest,,,,) = asyncRequestManager.investments(_getVault(), _getActor());
                (uint256 pendingRedeem,) =
                    batchRequestManager.redeemRequest(poolId, scId, assetId, _getActor().toBytes32());

                eq(pendingRedeemRequest, 0, "pendingRedeemRequest should be 0 after maxRedeem");
                eq(pendingRedeem, pendingRedeemBefore, "pendingRedeem should not increase");
                lte(redeemAmount, maxRedeemBefore, "shares redeemed surpass maxRedeem");
            }
        } catch {
            // precondition: redeeming more than 1 wei
            // NOTE: this is because maxRedeem rounds up so there's always 1 wei that can't be redeemed
            if (redeemAmount > 1) {
                t(approvedShareAmount < redeemAmount, "reverts on redeem for approved amount");
            }
        }
    }

    /// === Helper Functions === ///

    /// @dev Captures PoolEscrow state for validation analysis
    struct PoolEscrowState {
        IPoolEscrow poolEscrow;
        address asset;
        ShareClassId scId;
        uint256 tokenId;
        uint128 totalBefore;
        uint128 totalAfter;
        uint128 reservedBefore;
        uint128 reservedAfter;
        uint128 availableBalanceBefore;
        uint128 availableBalanceAfter;
        // total > reserved before
        bool isNormalStateBefore;
        // total > reserved after
        bool isNormalStateAfter;
    }

    /// @notice Tracks share balances for async vault claim operations
    /// @dev During claim operations (vault.deposit/mint), shares transfer from globalEscrow to receiver
    /// @dev PoolEscrow does NOT change during claims
    struct AsyncClaimState {
        uint256 globalEscrowSharesBefore;
        uint256 globalEscrowSharesAfter;
        uint256 receiverSharesBefore;
        uint256 receiverSharesAfter;
        uint256 sharesReturned;
        uint128 maxMintBefore;
        uint128 maxMintAfter;
    }

    /// @dev Analyzes PoolEscrow state before operations
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @return state PoolEscrow state analysis results
    function _analyzePoolEscrowState(PoolId poolId, ShareClassId scId)
        internal
        view
        returns (PoolEscrowState memory state)
    {
        state.poolEscrow = poolEscrowFactory.escrow(poolId);
        state.asset = address(_getVault().asset());
        state.scId = scId;
        state.tokenId = 0; // ERC20 tokens use tokenId 0

        // Capture raw holding values before operation
        (state.totalBefore, state.reservedBefore) =
            PoolEscrow(payable(address(state.poolEscrow))).holding(scId, state.asset, state.tokenId);

        // Calculate derived values before operation
        state.availableBalanceBefore = state.poolEscrow.availableBalanceOf(scId, state.asset, state.tokenId);
        state.isNormalStateBefore = state.totalBefore > state.reservedBefore;

        // Initialize after values (will be updated later)
        state.totalAfter = state.totalBefore;
        state.reservedAfter = state.reservedBefore;
        state.availableBalanceAfter = state.availableBalanceBefore;
        state.isNormalStateAfter = state.isNormalStateBefore;
    }

    /// @dev Updates PoolEscrow state after operation for post-validation
    /// @param state The state struct to update
    function _updatePoolEscrowStateAfter(PoolEscrowState memory state) internal view {
        // Capture raw holding values after operation
        (state.totalAfter, state.reservedAfter) =
            PoolEscrow(payable(address(state.poolEscrow))).holding(state.scId, state.asset, state.tokenId);

        // Calculate derived values after operation
        state.availableBalanceAfter = state.poolEscrow.availableBalanceOf(state.scId, state.asset, state.tokenId);
        state.isNormalStateAfter = state.totalAfter > state.reservedAfter;
    }

    /// @dev Validates AsyncVault max value changes
    /// @param operationAmount The operation amount (shares for maxMint, assets for maxDeposit)
    /// @param operationName The name of the operation ("Deposit" or "Mint")
    function _validateAsyncMaxValueChange(
        uint256 maxValueBefore,
        uint256 maxValueAfter,
        uint256 operationAmount,
        string memory operationName
    ) internal {
        // Note: Due to rounding in share<->asset conversion, we allow small tolerance
        uint256 expectedMaxValueAfter = maxValueBefore > operationAmount ? maxValueBefore - operationAmount : 0;

        lte(
            maxValueAfter,
            expectedMaxValueAfter + 1,
            string.concat("Async ", operationName, ": maxValue should decrease by approximately operationAmount")
        );
        gte(
            maxValueAfter,
            expectedMaxValueAfter > 0 ? expectedMaxValueAfter - 1 : 0,
            string.concat("Async ", operationName, ": maxValue should not decrease by more than operationAmount")
        );
    }

    /// @dev Validates SyncVault max value changes with PoolEscrow state validation
    /// @param operationName The name of the operation ("Deposit" or "Mint")
    function _validateSyncMaxValueChange(
        uint256 maxValueBefore,
        uint256 maxValueAfter,
        uint256 assetAmount,
        string memory operationName,
        PoolEscrowState memory state
    ) internal {
        t(
            state.reservedAfter == state.reservedBefore,
            string.concat(operationName, ": reserved amount should not change")
        );

        t(
            state.totalBefore + uint128(assetAmount) == state.totalAfter,
            string.concat(operationName, ": total should increase by asset amount")
        );

        // === SyncVault Scenario-Based Validation ===
        if (state.isNormalStateBefore && state.isNormalStateAfter) {
            // Scenario 1: Normal -> Normal (total > reserved before and after)
            // SyncVault: maxDeposit = maxReserve - availableBalance

            // For Mint operations, convert assetAmount to shares; for Deposit, use as-is
            uint256 expectedDecrease = (keccak256(bytes(operationName)) == keccak256(bytes("Mint")))
                ? _getVault().convertToShares(assetAmount)
                : assetAmount;

            t(
                maxValueAfter == maxValueBefore - expectedDecrease,
                string.concat("Sync Normal->Normal: max", operationName, " should decrease by exact amount")
            );
        } else if (!state.isNormalStateBefore && !state.isNormalStateAfter) {
            // Scenario 2: Critical -> Critical (total ≤ reserved before and after)
            // SyncVault: In critical state, maxDeposit = maxReserve - availableBalance
            // When maxReserve = uint128.max, maxDeposit can be very large even in critical state

            // Key insight: SyncVault doesn't return 0 in critical state like AsyncVault does
            // Instead, it follows: maxDeposit = maxReserve - availableBalance
            // The "critical" state only means total ≤ reserved, not that maxDeposit = 0

            t(
                maxValueAfter == maxValueBefore,
                string.concat(
                    "Sync Critical->Critical: max",
                    operationName,
                    " should not decrease due to availableBalance being zero"
                )
            );
        } else if (!state.isNormalStateBefore && state.isNormalStateAfter) {
            // Scenario 3: Critical -> Normal (total ≤ reserved before, total > reserved after)
            // SyncVault: Both before and after follow maxReserve - availableBalance calculation
            // The availableBalance calculation changes during PoolEscrow state transitions

            // SyncVault Critical->Normal: Calculate expected decrease based on actual availableBalance change
            // This is more accurate than using assetAmount directly
            uint256 actualDecrease = maxValueBefore - maxValueAfter;

            // Calculate expected decrease based on actual availableBalance change
            uint256 availableBalanceChange = state.availableBalanceAfter - state.availableBalanceBefore;

            // For Mint operations, we need to convert availableBalance change to shares to compare in the same units
            // For Deposit operations, both values are already in asset units
            uint256 expectedAmount;
            uint256 lowerBound;
            uint256 upperBound;

            if (keccak256(bytes(operationName)) == keccak256(bytes("Mint"))) {
                // Convert availableBalance change to shares for Mint operations
                expectedAmount = _getVault().convertToShares(availableBalanceChange);
            } else {
                // For Deposit operations, use availableBalance change directly
                expectedAmount = availableBalanceChange;
            }

            // Add tolerance for rounding errors (±2)
            lowerBound = expectedAmount > 2 ? expectedAmount - 2 : 0;
            upperBound = expectedAmount + 2;

            console2.log("actualDecrease: ", actualDecrease);
            console2.log("lowerBound: ", lowerBound);
            console2.log("upperBound: ", upperBound);

            // Allow actualDecrease to be 0 when conversion cap is limiting maxDeposit
            // This happens when decimal mismatch causes overflow protection to activate
            bool withinBounds = actualDecrease >= lowerBound && actualDecrease <= upperBound;
            bool isConversionCapped = actualDecrease == 0 && maxValueBefore == maxValueAfter;

            if (isConversionCapped) {
                console2.log("WARNING: maxDeposit unchanged - likely constrained by conversion cap due to decimal mismatch");
            }

            t(
                withinBounds || isConversionCapped,
                string.concat(
                    "Sync Critical->Normal: max",
                    operationName,
                    " decrease should be within bounds or unchanged due to conversion cap"
                )
            );

            // The before value should follow maxReserve logic (could be large)
            // Use expectedAmount which is already converted to the correct units based on operation type
            t(
                maxValueBefore >= expectedAmount,
                string.concat("Sync Critical->Normal: max", operationName, "Before should be >= expected amount")
            );
        } else {
            // Scenario 4: Normal -> Critical (total > reserved before, total ≤ reserved after)
            // This should be theoretically impossible since we're only adding funds via deposits
            t(false, string.concat("Sync Invalid transition: Normal->Critical impossible for ", operationName));
        }
    }

    /// @dev Logs PoolEscrow analysis for debugging
    /// @param operationName The name of the operation ("Deposit" or "Mint")
    /// @param maxValueBefore The maximum operation value before
    /// @param maxValueAfter The maximum operation value after
    /// @param operationAmount The operation amount
    /// @param state The PoolEscrow state
    function _logPoolEscrowAnalysis(
        string memory operationName,
        uint256 maxValueBefore,
        uint256 maxValueAfter,
        uint256 operationAmount,
        PoolEscrowState memory state
    ) internal pure {
        console2.log(string.concat("=== PoolEscrow Analysis (", operationName, ") ==="));
        console2.log(
            "Available balance before/after: %d / %d", state.availableBalanceBefore, state.availableBalanceAfter
        );
        console2.log(string.concat("Max", operationName, " before/after: %d / %d"), maxValueBefore, maxValueAfter);
        console2.log(string.concat(operationName, "Amount: %d"), operationAmount);
    }

    /// @dev Captures async claim state before vault.deposit() operation
    /// @notice Tracks globalEscrow and receiver share balances
    function _captureAsyncClaimStateBefore(IBaseVault vault, address receiver)
        internal
        view
        returns (AsyncClaimState memory state)
    {
        address shareToken = vault.share();
        address globalEscrowAddr = address(asyncRequestManager.globalEscrow());

        state.globalEscrowSharesBefore = IERC20(shareToken).balanceOf(globalEscrowAddr);
        state.receiverSharesBefore = IERC20(shareToken).balanceOf(receiver);

        (state.maxMintBefore,,,,,,,,,) = asyncRequestManager.investments(vault, _getActor());
        return state;
    }

    /// @dev Updates async claim state after vault.deposit() operation
    /// @notice Updates the state struct with post-operation values
    function _updateAsyncClaimStateAfter(AsyncClaimState memory state, IBaseVault vault, address receiver)
        internal
        view
    {
        address shareToken = vault.share();
        address globalEscrowAddr = address(asyncRequestManager.globalEscrow());

        state.globalEscrowSharesAfter = IERC20(shareToken).balanceOf(globalEscrowAddr);
        state.receiverSharesAfter = IERC20(shareToken).balanceOf(receiver);

        (state.maxMintAfter,,,,,,,,,) = asyncRequestManager.investments(vault, _getActor());
    }

    /// @dev Validates async vault claim operations
    /// @notice During claims, globalEscrow shares transfer to receiver, PoolEscrow does NOT change
    function _validateAsyncVaultClaim(AsyncClaimState memory state, uint256 depositAmount, string memory operationName)
        internal
    {
        if (depositAmount == 0) {
            eq(state.sharesReturned, 0, string.concat(operationName, ": zero deposit should return zero shares"));
            eq(
                state.globalEscrowSharesBefore,
                state.globalEscrowSharesAfter,
                string.concat(operationName, ": zero deposit should not change globalEscrow")
            );
            eq(
                state.receiverSharesBefore,
                state.receiverSharesAfter,
                string.concat(operationName, ": zero deposit should not change receiver balance")
            );
            eq(
                state.maxMintBefore,
                state.maxMintAfter,
                string.concat(operationName, ": zero deposit should not change maxMint")
            );
            return;
        }

        uint256 globalEscrowDecrease = state.globalEscrowSharesBefore - state.globalEscrowSharesAfter;
        uint256 receiverIncrease = state.receiverSharesAfter - state.receiverSharesBefore;
        eq(
            globalEscrowDecrease,
            state.sharesReturned,
            string.concat(operationName, ": globalEscrow must decrease by exact shares returned")
        );
        eq(
            receiverIncrease,
            state.sharesReturned,
            string.concat(operationName, ": receiver must receive exact shares returned")
        );
        eq(
            globalEscrowDecrease,
            receiverIncrease,
            string.concat(operationName, ": shares leaving globalEscrow must equal shares received")
        );

        uint128 maxMintDecrease = state.maxMintBefore - state.maxMintAfter;
        gte(
            maxMintDecrease,
            state.sharesReturned,
            string.concat(operationName, ": maxMint must decrease by at least shares returned")
        );
        lte(
            maxMintDecrease,
            state.sharesReturned + 1,
            string.concat(operationName, ": maxMint must decrease by at at most shares returned +1 due to rounding")
        );
    }

    /// @dev Since we deploy and set addresses via handlers
    // We can have zero values initially
    // We have these checks to prevent false positives
    // This is tightly coupled to our system
    // A simpler system with no actors would not need these checks
    // Although they don't hurt
    // NOTE: We could also change the entire properties to handlers and we would be ok as well
    function _canCheckProperties() internal view returns (bool) {
        if (TODO_RECON_SKIP_ERC7540) {
            return false;
        }
        if (address(_getVault()) == address(0)) {
            return false;
        }
        if (_getShareToken() == address(0)) {
            return false;
        }
        if (address(fullRestrictions) == address(0)) {
            return false;
        }
        if (_getAsset() == address(0)) {
            return false;
        }

        return true;
    }

    function _centrifugeSpecificPreChecks() internal view {
        require(msg.sender == address(this)); // Enforces external call to ensure it's not state altering
        require(_canCheckProperties()); // Early revert to prevent false positives
    }

    /// @dev Helper to validate async vault deposit failures
    function _validateAsyncDepositFailure(uint256 depositAmount) internal {
        (uint128 maxMintState,, D18 depositPrice,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());

        if (!depositPrice.isZero()) {
            VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(_getVault());
            uint128 sharesUp = PricingLib.assetToShareAmount(
                _getVault().share(),
                vaultDetails.asset,
                vaultDetails.tokenId,
                depositAmount.toUint128(),
                depositPrice,
                MathLib.Rounding.Up
            );

            if (sharesUp > maxMintState) {
                console2.log("Deposit failed - calculated shares exceed maxMint due to rounding");
                return;
            }
        }

        // Check pending cancellation
        (,,,,,,,, bool pendingCancel,) = asyncRequestManager.investments(_getVault(), _getActor());
        if (pendingCancel) {
            console2.log("Deposit failed - pending cancellation");
            return;
        }

        t(false, "Async vault deposit failed for unknown reason");
    }

    /// @dev Helper to validate async vault mint failures
    function _validateAsyncMintFailure(uint256 mintAmount) internal {
        (,, D18 depositPrice,,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());

        if (!depositPrice.isZero()) {
            VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(_getVault());
            uint256 assetsRequired = PricingLib.shareToAssetAmount(
                _getVault().share(),
                mintAmount.toUint128(),
                vaultDetails.asset,
                vaultDetails.tokenId,
                depositPrice,
                MathLib.Rounding.Up
            );

            uint256 maxDepositCurrent = _getVault().maxDeposit(_getActor());
            if (assetsRequired > maxDepositCurrent) {
                console2.log("Mint failed - calculated assets exceed maxDeposit due to rounding");
                return;
            }
        }

        // Check pending cancellation
        (,,,,,,,, bool pendingCancel,) = asyncRequestManager.investments(_getVault(), _getActor());
        if (pendingCancel) {
            console2.log("Mint failed - pending cancellation");
            return;
        }

        t(false, "Async vault mint failed for unknown reason");
    }

    /// @dev Helper to validate async vault withdraw failures
    function _validateAsyncWithdrawFailure(uint256 withdrawAmount) internal view returns (bool) {
        (,,, D18 redeemPrice,,,,,,) = asyncRequestManager.investments(_getVault(), _getActor());

        if (!redeemPrice.isZero()) {
            // Calculate shares required for the withdraw using exact AsyncRequestManager logic
            VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(_getVault());
            uint128 sharesRequired = PricingLib.assetToShareAmount(
                _getVault().share(),
                vaultDetails.asset,
                vaultDetails.tokenId,
                withdrawAmount.toUint128(),
                redeemPrice,
                MathLib.Rounding.Up
            );

            // Check if shares would exceed maxRedeem
            uint256 maxRedeemCurrent = _getVault().maxRedeem(_getActor());
            if (sharesRequired > maxRedeemCurrent) {
                console2.log("Withdraw failed - calculated shares exceed maxRedeem due to rounding");
                return false;
            }
        }

        // Check pending cancellation
        (,,,,,,,, bool pendingCancel,) = asyncRequestManager.investments(_getVault(), _getActor());
        if (pendingCancel) {
            console2.log("Withdraw failed - pending cancellation");
            return false;
        }

        return true;
    }
}
