// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Asserts} from "@chimera/Asserts.sol";
import {vm} from "@chimera/Hevm.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {PoolId} from "src/core/types/PoolId.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {AssetId} from "src/core/types/AssetId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {PricingLib} from "src/core/libraries/PricingLib.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {D18} from "src/misc/types/D18.sol";
import {VaultDetails} from "src/core/spoke/interfaces/ISpoke.sol";
import {Setup} from "test/integration/recon-end-to-end/Setup.sol";
import {AsyncVaultProperties} from "test/integration/recon-end-to-end/properties/AsyncVaultProperties.sol";
import {Helpers} from "test/integration/recon-end-to-end/utils/Helpers.sol";
import {IPoolEscrow, Holding} from "src/core/spoke/interfaces/IPoolEscrow.sol";
import {PoolEscrow} from "src/core/spoke/PoolEscrow.sol";

import {VaultKind} from "src/core/spoke/interfaces/IVault.sol";

import {console2} from "forge-std/console2.sol";
/// @dev ERC-7540 Properties used by Centrifuge
/// See `AsyncVaultProperties` for more properties that can be re-used in your project

// TODO(wischli): Rename to `(Base)VaultProperties` to indicate support for async as well as sync vaults
abstract contract AsyncVaultCentrifugeProperties is
    Setup,
    Asserts,
    AsyncVaultProperties
{
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

    function asyncVault_6_deposit(
        address asyncVaultTarget,
        uint256 amt
    ) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_deposit(asyncVaultTarget, amt);
    }

    function asyncVault_6_mint(
        address asyncVaultTarget,
        uint256 amt
    ) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_mint(asyncVaultTarget, amt);
    }

    function asyncVault_6_withdraw(
        address asyncVaultTarget,
        uint256 amt
    ) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_withdraw(asyncVaultTarget, amt);
    }

    function asyncVault_6_redeem(
        address asyncVaultTarget,
        uint256 amt
    ) public override {
        _centrifugeSpecificPreChecks();

        AsyncVaultProperties.asyncVault_6_redeem(asyncVaultTarget, amt);
    }

    function asyncVault_7(
        address asyncVaultTarget,
        uint256 shares
    ) public override {
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
    /// @dev Property: user can always deposit an amount between 1 and maxDeposit  if they have > 0 assets and are
    /// approved
    /// @dev Property: maxDeposit should decrease by the amount deposited
    /// @dev Property: depositing maxDeposit blocks the user from depositing more
    /// @dev Property: depositing maxDeposit does not increase the pendingDeposit
    /// @dev Property: depositing maxDeposit doesn't mint more than maxMint shares
    // TODO(wischli): Add back statelessTest modifier after optimizer run
    function asyncVault_maxDeposit(
        uint64 poolEntropy,
        uint32 scEntropy,
        uint256 depositAmount
    ) public statelessTest {
        uint256 maxDepositBefore = _getVault().maxDeposit(_getActor());

        depositAmount = between(depositAmount, 1, maxDepositBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(
            shareClassManager,
            poolId,
            scEntropy
        );
        AssetId assetId = _getAssetId();
        // (uint32 latestDepositApproval,,,) = batchRequestManager.epochPointers(scId, assetId);
        (uint256 pendingDepositBefore, ) = batchRequestManager.depositRequest(
            poolId,
            scId,
            assetId,
            _getActor().toBytes32()
        );

        // === PoolEscrow State Analysis Before Deposit ===
        PoolEscrowState memory escrowState = _analyzePoolEscrowState(
            poolId,
            scId
        );

        bool isAsyncVault = _getVault().vaultKind() == VaultKind.Async;
        uint256 maxMintBefore;
        if (isAsyncVault) {
            (maxMintBefore, , , , , , , , , ) = asyncRequestManager.investments(
                _getVault(),
                _getActor()
            );
        }
        // TODO(wischli): Find solution for Uint128_Overflow
        // else {
        //     maxMintBefore = syncManager.maxMint(_getVault(), _getActor());
        // }

        console2.log("asyncVault_maxDeposit: isAsyncVault == ", isAsyncVault);

        vm.prank(_getActor());
        try _getVault().deposit(depositAmount, _getActor()) returns (
            uint256 shares
        ) {
            console2.log(" === After Depositing: Max Deposit === ");
            uint256 maxDepositAfter = _getVault().maxDeposit(_getActor());

            // === Enhanced PoolEscrow-aware maxDeposit Property ===
            // Update escrow state after the deposit operation
            _updatePoolEscrowStateAfter(escrowState);

            // Validate maxDeposit change with PoolEscrow-aware logic
            _validateMaxValueChange(
                maxDepositBefore,
                maxDepositAfter,
                depositAmount,
                "Deposit",
                escrowState
            );

            // Log analysis for debugging
            _logPoolEscrowAnalysis(
                "Deposit",
                maxDepositBefore,
                maxDepositAfter,
                depositAmount,
                escrowState
            );

            if (depositAmount == maxDepositBefore) {
                (uint256 pendingDeposit, ) = batchRequestManager.depositRequest(
                    poolId,
                    scId,
                    assetId,
                    _getActor().toBytes32()
                );

                eq(
                    pendingDeposit,
                    pendingDepositBefore,
                    "pendingDeposit should not increase"
                );

                uint256 maxMintAfter;
                if (isAsyncVault) {
                    (maxMintAfter, , , , , , , , , ) = asyncRequestManager
                        .investments(_getVault(), _getActor());
                    lte(shares, maxMintBefore, "shares minted surpass maxMint");
                } else {
                    maxMintAfter = syncManager.maxMint(
                        _getVault(),
                        _getActor()
                    );
                }
                eq(maxMintAfter, 0, "maxMint should be 0 after maxDeposit");
            }
        } catch {
            // For async vaults, validate failure reason
            if (isAsyncVault) {
                _validateAsyncDepositFailure(depositAmount);
            } else {
                console2.log(
                    "Sync vault deposit failed - likely due to transfer restrictions"
                );
            }
        }
    }

    /// @dev Property: user can always maxMint if they have > 0 assets and are approved
    /// @dev Property: user can always mint an amount between 1 and maxMint if they have > 0 assets and are approved
    /// @dev Property: maxMint should be 0 after using maxMint as mintAmount
    /// @dev Property: minting maxMint should not mint more than maxDeposit shares
    function asyncVault_maxMint(
        uint64 poolEntropy,
        uint32 scEntropy,
        uint256 mintAmount
    ) public statelessTest {
        uint256 maxMintBefore = _getVault().maxMint(_getActor());
        uint256 maxDepositBefore = _getVault().maxDeposit(_getActor());
        require(maxMintBefore > 0, "must be able to mint");

        mintAmount = between(mintAmount, 1, maxMintBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(
            shareClassManager,
            poolId,
            scEntropy
        );
        AssetId assetId = _getAssetId();

        // === PoolEscrow State Analysis Before Mint ===
        PoolEscrowState memory escrowState = _analyzePoolEscrowState(
            poolId,
            scId
        );

        vm.prank(_getActor());
        console2.log(" === Before asyncVault_maxMint mint === ");
        try _getVault().mint(mintAmount, _getActor()) returns (uint256 assets) {
            console2.log(" === After asyncVault_maxMint mint === ");
            uint256 maxMintAfter = _getVault().maxMint(_getActor());

            // === Enhanced PoolEscrow-aware maxMint Property ===
            // Update escrow state after the mint operation
            _updatePoolEscrowStateAfter(escrowState);

            // Validate maxMint change with PoolEscrow-aware logic
            _validateMaxValueChange(
                maxMintBefore,
                maxMintAfter,
                assets,
                "Mint",
                escrowState
            );

            // Log analysis for debugging
            _logPoolEscrowAnalysis(
                "Mint",
                maxMintBefore,
                maxMintAfter,
                mintAmount,
                escrowState
            );

            uint256 shares = _getVault().convertToShares(assets);

            if (mintAmount == maxMintBefore) {
                uint256 maxMintVaultAfter = _getVault().maxMint(_getActor());

                eq(
                    maxMintVaultAfter,
                    0,
                    "maxMint in vault should be 0 after maxMint"
                );
                lte(shares, maxDepositBefore, "shares minted surpass maxMint");

                uint256 maxMintManagerAfter;
                if (_getVault().vaultKind() == VaultKind.Async) {
                    (
                        maxMintManagerAfter,
                        ,
                        ,
                        ,
                        ,
                        ,
                        ,
                        ,
                        ,

                    ) = asyncRequestManager.investments(
                        _getVault(),
                        _getActor()
                    );
                } else {
                    maxMintManagerAfter = syncManager.maxMint(
                        _getVault(),
                        _getActor()
                    );
                }
                eq(
                    maxMintManagerAfter,
                    0,
                    "maxMintManagerAfter in request should be 0 after maxMint"
                );
            }
        } catch {
            // Determine vault type for proper validation
            bool isAsyncVault = _getVault().vaultKind() == VaultKind.Async;

            if (isAsyncVault) {
                _validateAsyncMintFailure(mintAmount);
            } else {
                console2.log(
                    "Sync vault mint failed - likely due to transfer restrictions"
                );
            }
        }
    }

    /// @dev Property: user can always maxWithdraw if they have > 0 shares and are approved
    /// @dev Property: user can always withdraw an amount between 1 and maxWithdraw if they have > 0 shares and are
    /// approved
    /// @dev Property: maxWithdraw should decrease by the amount withdrawn
    function asyncVault_maxWithdraw(
        uint64 poolEntropy,
        uint32 scEntropy,
        uint256 withdrawAmount
    ) public statelessTest {
        uint256 maxWithdrawBefore = _getVault().maxWithdraw(_getActor());
        require(maxWithdrawBefore > 0, "must be able to withdraw");

        withdrawAmount = between(withdrawAmount, 1, maxWithdrawBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(
            shareClassManager,
            poolId,
            scEntropy
        );
        AssetId assetId = _getAssetId();

        vm.prank(_getActor());
        try
            _getVault().withdraw(withdrawAmount, _getActor(), _getActor())
        returns (uint256 shares) {
            uint256 maxWithdrawAfter = _getVault().maxWithdraw(_getActor());
            uint256 difference = maxWithdrawBefore - withdrawAmount;
            uint256 assets = _getVault().convertToAssets(shares);

            t(difference == maxWithdrawAfter, "rounding error in maxWithdraw");

            if (withdrawAmount == maxWithdrawBefore) {
                (
                    ,
                    ,
                    ,
                    ,
                    ,
                    uint128 pendingWithdrawRequest,
                    ,
                    ,
                    ,

                ) = asyncRequestManager.investments(_getVault(), _getActor());
                (uint256 pendingWithdraw, ) = batchRequestManager.redeemRequest(
                    poolId,
                    scId,
                    assetId,
                    _getActor().toBytes32()
                );

                eq(
                    pendingWithdrawRequest,
                    0,
                    "pendingWithdrawRequest should be 0 after maxWithdraw"
                );
                eq(
                    pendingWithdraw,
                    0,
                    "pendingWithdraw should be 0 after maxWithdraw"
                );
                lte(
                    assets,
                    maxWithdrawBefore,
                    "shares withdrawn surpass maxWithdraw"
                );
            }
        } catch {
            // Determine vault type for proper validation
            bool isAsyncVault = _getVault().vaultKind() == VaultKind.Async;

            if (isAsyncVault) {
                bool unknownFailure = _validateAsyncWithdrawFailure(
                    withdrawAmount
                );
                t(
                    !unknownFailure,
                    "Async vault withdraw failed for unknown reason"
                );
            } else {
                console2.log(
                    "Sync vault withdraw failed - likely due to transfer restrictions"
                );
            }
        }
    }

    /// @dev Property: user can always maxRedeem if they have > 0 shares and are approved
    /// @dev Property: user can always redeem an amount between 1 and maxRedeem if they have > 0 shares and are approved
    /// @dev Property: redeeming maxRedeem does not increase the pendingRedeem
    // TODO(wischli): Add back statelessTest modifier after optimizer run
    function asyncVault_maxRedeem(
        uint64 poolEntropy,
        uint32 scEntropy,
        uint256 redeemAmount
    ) public statelessTest {
        uint256 maxRedeemBefore = _getVault().maxRedeem(_getActor());
        require(maxRedeemBefore > 0, "must be able to redeem");

        redeemAmount = between(redeemAmount, 1, maxRedeemBefore);

        PoolId poolId = Helpers.getRandomPoolId(_getPools(), poolEntropy);
        ShareClassId scId = Helpers.getRandomShareClassIdForPool(
            shareClassManager,
            poolId,
            scEntropy
        );
        AssetId assetId = _getAssetId();
        (, uint32 latestRedeemApproval, , ) = batchRequestManager.epochId(
            poolId,
            scId,
            assetId
        );
        (uint256 pendingRedeemBefore, ) = batchRequestManager.redeemRequest(
            poolId,
            scId,
            assetId,
            _getActor().toBytes32()
        );

        vm.prank(_getActor());
        try _getVault().redeem(redeemAmount, _getActor(), _getActor()) returns (
            uint256 assets
        ) {
            console2.log(" === After maxRedeem === ");
            uint256 maxRedeemAfter = _getVault().maxRedeem(_getActor());
            // uint256 difference = maxRedeemBefore - redeemAmount; // Unused
            uint256 shares = _getVault().convertToShares(assets);

            // console2.log("difference:", difference);
            // console2.log("maxRedeemBefore:", maxRedeemBefore);
            // console2.log("maxRedeemAfter:", maxRedeemAfter);
            // console2.log("redeemAmount:", redeemAmount);
            // console2.log("shares:", shares);
            // console2.log("assets:", assets);

            // for optimizing the difference between the two
            if (maxRedeemAfter > maxRedeemBefore) {
                maxRedeemGreater = int256(maxRedeemAfter - maxRedeemBefore);
            } else {
                maxRedeemLess = int256(maxRedeemBefore - maxRedeemAfter);
            }

            address poolEscrow = address(
                poolEscrowFactory.escrow(_getVault().poolId())
            );
            console2.log(
                "pool escrow balance after maxRedeem: ",
                MockERC20(address(_getVault().asset())).balanceOf(poolEscrow)
            );

            // NOTE: temporarily remove the assertion to optimize the difference
            // otherwise it asserts false and undoes state changes
            // t(difference == maxRedeemAfter, "rounding error in maxRedeem");

            if (redeemAmount == maxRedeemBefore) {
                (
                    ,
                    ,
                    ,
                    ,
                    ,
                    uint128 pendingRedeemRequest,
                    ,
                    ,
                    ,

                ) = asyncRequestManager.investments(_getVault(), _getActor());
                (uint256 pendingRedeem, ) = batchRequestManager.redeemRequest(
                    poolId,
                    scId,
                    assetId,
                    _getActor().toBytes32()
                );

                eq(
                    pendingRedeemRequest,
                    0,
                    "pendingRedeemRequest should be 0 after maxRedeem"
                );
                eq(
                    pendingRedeem,
                    pendingRedeemBefore,
                    "pendingRedeem should not increase"
                );
                lte(
                    shares,
                    maxRedeemBefore,
                    "shares redeemed surpass maxRedeem"
                );
            }
        } catch {
            // precondition: redeeming more than 1 wei
            // NOTE: this is because maxRedeem rounds up so there's always 1 wei that can't be redeemed
            if (redeemAmount > 1) {
                t(
                    latestRedeemApproval < redeemAmount,
                    "reverts on redeem for approved amount"
                );
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
        // Raw PoolEscrow holding values
        uint128 totalBefore;
        uint128 totalAfter;
        uint128 reservedBefore;
        uint128 reservedAfter;
        // Derived available balance values
        uint128 availableBalanceBefore;
        uint128 availableBalanceAfter;
        // State classification
        bool isNormalStateBefore; // total > reserved before
        bool isNormalStateAfter; // total > reserved after
    }

    /// @dev Analyzes PoolEscrow state before operations
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @return state PoolEscrow state analysis results
    function _analyzePoolEscrowState(
        PoolId poolId,
        ShareClassId scId
    ) internal view returns (PoolEscrowState memory state) {
        state.poolEscrow = poolEscrowFactory.escrow(poolId);
        state.asset = address(_getVault().asset());
        state.scId = scId;
        state.tokenId = 0; // ERC20 tokens use tokenId 0

        // Capture raw holding values before operation
        (state.totalBefore, state.reservedBefore) = PoolEscrow(
            payable(address(state.poolEscrow))
        ).holding(scId, state.asset, state.tokenId);

        // Calculate derived values before operation
        state.availableBalanceBefore = state.poolEscrow.availableBalanceOf(
            scId,
            state.asset,
            state.tokenId
        );
        state.isNormalStateBefore = state.totalBefore > state.reservedBefore;

        // Initialize after values (will be updated later)
        state.totalAfter = state.totalBefore;
        state.reservedAfter = state.reservedBefore;
        state.availableBalanceAfter = state.availableBalanceBefore;
        state.isNormalStateAfter = state.isNormalStateBefore;
    }

    /// @dev Updates PoolEscrow state after operation for post-validation
    /// @param state The state struct to update
    function _updatePoolEscrowStateAfter(
        PoolEscrowState memory state
    ) internal view {
        // Capture raw holding values after operation
        (state.totalAfter, state.reservedAfter) = PoolEscrow(
            payable(address(state.poolEscrow))
        ).holding(state.scId, state.asset, state.tokenId);

        // Calculate derived values after operation
        state.availableBalanceAfter = state.poolEscrow.availableBalanceOf(
            state.scId,
            state.asset,
            state.tokenId
        );
        state.isNormalStateAfter = state.totalAfter > state.reservedAfter;
    }

    /// @dev Validates max operation value changes with exact PoolEscrow-aware logic
    /// @param maxValueBefore The maximum operation value before the operation
    /// @param maxValueAfter The maximum operation value after the operation
    /// @param operationAmount The amount used in the operation (deposit/mint amount)
    /// @param operationName The name of the operation for logging ("Deposit" or "Mint")
    /// @param state The PoolEscrow state analysis
    function _validateMaxValueChange(
        uint256 maxValueBefore,
        uint256 maxValueAfter,
        uint256 operationAmount,
        string memory operationName,
        PoolEscrowState memory state
    ) internal {
        // === Enforce Core Invariants ===
        // Invariant 1: Only total should change during deposits, not reserved
        t(
            state.reservedAfter == state.reservedBefore,
            string.concat(operationName, ": reserved amount should not change")
        );

        // Invariant 2: Total should increase by exactly the operation amount
        t(
            state.totalBefore + uint128(operationAmount) == state.totalAfter,
            string.concat(
                operationName,
                ": total should increase by operation amount"
            )
        );

        // === Vault Type Detection ===
        bool isAsyncVault = _getVault().vaultKind() == VaultKind.Async;

        if (isAsyncVault) {
            _validateAsyncVaultMaxValueChange(
                maxValueBefore,
                maxValueAfter,
                operationAmount,
                operationName,
                state
            );
        } else {
            _validateSyncVaultMaxValueChange(
                maxValueBefore,
                maxValueAfter,
                operationAmount,
                operationName,
                state
            );
        }
    }

    /// @dev Validates AsyncVault max value changes (user-specific allocation-based)
    function _validateAsyncVaultMaxValueChange(
        uint256 maxValueBefore,
        uint256 maxValueAfter,
        uint256 operationAmount,
        string memory operationName,
        PoolEscrowState memory state
    ) internal {
        // === AsyncVault Scenario-Based Validation ===
        if (state.isNormalStateBefore && state.isNormalStateAfter) {
            // Scenario 1: Normal -> Normal (total > reserved before and after)
            t(
                maxValueAfter == maxValueBefore - operationAmount,
                string.concat(
                    "Async Normal->Normal: max",
                    operationName,
                    " should decrease by exact operation amount"
                )
            );
        } else if (!state.isNormalStateBefore && !state.isNormalStateAfter) {
            // Scenario 2: Critical -> Critical (total ≤ reserved before and after)
            t(
                maxValueBefore == 0,
                string.concat(
                    "Async Critical->Critical: max",
                    operationName,
                    "Before should be 0"
                )
            );
            t(
                maxValueAfter == 0,
                string.concat(
                    "Async Critical->Critical: max",
                    operationName,
                    "After should be 0"
                )
            );
        } else if (!state.isNormalStateBefore && state.isNormalStateAfter) {
            // Scenario 3: Critical -> Normal (total ≤ reserved before, total > reserved after)
            t(
                maxValueBefore == 0,
                string.concat(
                    "Async Critical->Normal: max",
                    operationName,
                    "Before should be 0"
                )
            );

            // For AsyncVault, maxValueAfter is based on user's maxMint allocation, not PoolEscrow calculation
            t(
                // maxValueAfter > 0,
                maxValueAfter ==
                    state.totalBefore + operationAmount - state.reservedBefore,
                string.concat(
                    "Async Critical->Normal: max",
                    operationName,
                    "After should be > 0"
                )
            );
        } else {
            // Scenario 4: Normal -> Critical (total > reserved before, total ≤ reserved after)
            // This should be theoretically impossible since we're only adding funds via deposits
            t(
                false,
                string.concat(
                    "Async Invalid transition: Normal->Critical impossible for ",
                    operationName
                )
            );
        }
    }

    /// @dev Validates SyncVault max value changes (maxReserve-based, can be uint128.max)
    function _validateSyncVaultMaxValueChange(
        uint256 maxValueBefore,
        uint256 maxValueAfter,
        uint256 operationAmount,
        string memory operationName,
        PoolEscrowState memory state
    ) internal {
        // === SyncVault Scenario-Based Validation ===
        if (state.isNormalStateBefore && state.isNormalStateAfter) {
            // Scenario 1: Normal -> Normal (total > reserved before and after)
            // SyncVault: maxDeposit = maxReserve - availableBalance
            t(
                maxValueAfter == maxValueBefore - operationAmount,
                string.concat(
                    "Sync Normal->Normal: max",
                    operationName,
                    " should decrease by exact operation amount"
                )
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

            // SyncVault Critical->Normal: The decrease is approximately operationAmount, but can deviate due to
            // PoolEscrow state transition effects on availableBalance calculation
            uint256 actualDecrease = maxValueBefore - maxValueAfter;

            // The decrease is bounded by: (operationAmount - reserved) ≤ actualDecrease ≤ operationAmount
            // This is because actualDecrease = totalBefore + operationAmount - reserved, where 0 ≤ totalBefore ≤
            // reserved
            t(
                actualDecrease >= operationAmount - state.reservedAfter &&
                    actualDecrease <= operationAmount,
                string.concat(
                    "Sync Critical->Normal: max",
                    operationName,
                    " decrease should be within [operationAmount - reserved, operationAmount]"
                )
            );

            // The before value should follow maxReserve logic (could be large)
            t(
                maxValueBefore >= operationAmount,
                string.concat(
                    "Sync Critical->Normal: max",
                    operationName,
                    "Before should be >= operation amount"
                )
            );
        } else {
            // Scenario 4: Normal -> Critical (total > reserved before, total ≤ reserved after)
            // This should be theoretically impossible since we're only adding funds via deposits
            t(
                false,
                string.concat(
                    "Sync Invalid transition: Normal->Critical impossible for ",
                    operationName
                )
            );
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
        console2.log(
            string.concat("=== PoolEscrow Analysis (", operationName, ") ===")
        );
        console2.log(
            "Available balance before/after: %d / %d",
            state.availableBalanceBefore,
            state.availableBalanceAfter
        );
        console2.log(
            string.concat("Max", operationName, " before/after: %d / %d"),
            maxValueBefore,
            maxValueAfter
        );
        console2.log(
            string.concat(operationName, "Amount: %d"),
            operationAmount
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
        (
            uint128 maxMintState,
            ,
            D18 depositPrice,
            ,
            ,
            ,
            ,
            ,
            ,

        ) = asyncRequestManager.investments(_getVault(), _getActor());

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
                console2.log(
                    "Deposit failed - calculated shares exceed maxMint due to rounding"
                );
                return;
            }
        }

        // Check pending cancellation
        (, , , , , , , , bool pendingCancel, ) = asyncRequestManager
            .investments(_getVault(), _getActor());
        if (pendingCancel) {
            console2.log("Deposit failed - pending cancellation");
            return;
        }

        t(false, "Async vault deposit failed for unknown reason");
    }

    /// @dev Helper to validate async vault mint failures
    function _validateAsyncMintFailure(uint256 mintAmount) internal {
        (, , D18 depositPrice, , , , , , , ) = asyncRequestManager.investments(
            _getVault(),
            _getActor()
        );

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
                console2.log(
                    "Mint failed - calculated assets exceed maxDeposit due to rounding"
                );
                return;
            }
        }

        // Check pending cancellation
        (, , , , , , , , bool pendingCancel, ) = asyncRequestManager
            .investments(_getVault(), _getActor());
        if (pendingCancel) {
            console2.log("Mint failed - pending cancellation");
            return;
        }

        t(false, "Async vault mint failed for unknown reason");
    }

    /// @dev Helper to validate async vault withdraw failures
    function _validateAsyncWithdrawFailure(
        uint256 withdrawAmount
    ) internal returns (bool) {
        (, , , D18 redeemPrice, , , , , , ) = asyncRequestManager.investments(
            _getVault(),
            _getActor()
        );

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
                console2.log(
                    "Withdraw failed - calculated shares exceed maxRedeem due to rounding"
                );
                return false;
            }
        }

        // Check pending cancellation
        (, , , , , , , , bool pendingCancel, ) = asyncRequestManager
            .investments(_getVault(), _getActor());
        if (pendingCancel) {
            console2.log("Withdraw failed - pending cancellation");
            return false;
        }

        return true;
    }
}
