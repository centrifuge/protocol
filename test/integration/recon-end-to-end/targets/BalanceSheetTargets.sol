// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {D18, d18} from "../../../../src/misc/types/D18.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {PoolEscrow} from "../../../../src/core/spoke/PoolEscrow.sol";
import {BalanceSheet} from "../../../../src/core/spoke/BalanceSheet.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";

import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";
import {REASON_DEPOSIT} from "../../../../src/vaults/interfaces/IVaultManagers.sol";

import {Panic} from "@recon/Panic.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {IShareToken} from "../../../../src/token/interfaces/IShareToken.sol";

// Helpers

abstract contract BalanceSheetTargets is BaseTargetFunctions, Properties {
    /// CUSTOM TARGET FUNCTIONS - Add your own target functions here ///
    /// AUTO GENERATED TARGET FUNCTIONS - WARNING: DO NOT DELETE OR MODIFY THIS LINE ///
    // NOTE: removed because introduces false positives with auth checks
    // function balanceSheet_deny() public updateGhosts asActor {
    //     // Track authorization - deny() requires auth (ward only)
    //     _trackAuthorization(_getActor(), PoolId.wrap(0)); // Global operation, use PoolId 0
    //     _checkAndRecordAuthChange(_getActor()); // Track auth changes from deny()

    //     balanceSheet.deny(_getActor());
    // }

    function balanceSheet_deposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeV3_1_0.vaultDetails(vault).assetId;
        _captureShareQueueState(poolId, scId);

        // Track authorization - deposit() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track for property iteration
        // NOTE: replaced with values from manager
        // _trackPoolAndShareClass(poolId, scId);
        // _trackAsset(assetId);

        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));

        // Track escrow balance sufficiency
        ghost_escrowSufficiencyTracked[assetKey] = true;

        // Track asset-share proportionality for deposits
        // Track deposit amounts and exchange rate before deposit
        ghost_cumulativeAssetsDeposited[assetKey] += amount;
        ghost_depositProportionalityTracked[assetKey] = true;

        // Get current exchange rate (price per asset in pool terms)
        try spokeRegistry.pricePoolPerAsset(poolId, scId, assetId, true) returns (D18 pricePerAsset) {
            // Store weighted average exchange rate
            uint256 totalOps = 1; // Simplified tracking
            if (totalOps == 1) {
                ghost_depositExchangeRate[assetKey] = D18.unwrap(pricePerAsset);
            } else {
                // Update running average: new_avg = (old_avg * (n-1) + new_value) / n
                uint256 oldAvg = ghost_depositExchangeRate[assetKey];
                ghost_depositExchangeRate[assetKey] = (oldAvg * (totalOps - 1) + D18.unwrap(pricePerAsset)) / totalOps;
            }
        } catch {
            // If price fetch fails, use 1:1 ratio as fallback
            ghost_depositExchangeRate[assetKey] = D18.unwrap(d18(1 ether));
        }

        balanceSheet.deposit(poolId, scId, vault.asset(), tokenId, amount);

        sumOfManagerDeposits[vault.asset()] += amount;

        ghost_assetQueueDeposits[assetKey] += amount;

        // Update escrow tracking: total balance increases by deposit amount
        uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
        ghost_escrowAvailableBalance[assetKey] = newAvailable;
        ghost_escrowReservedBalance[assetKey] = ghost_netReserved[assetKey];
    }

    function balanceSheet_issue(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        _captureShareQueueState(poolId, scId);

        // Track authorization - issue() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track for property iteration
        // _trackPoolAndShareClass(poolId, scId);

        // Track previous net position for flip detection
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));

        // Track supply operations
        ghost_supplyOperationOccurred[shareKey] = true;
        ghost_totalShareSupply[shareKey] += shares;
        ghost_supplyMintEvents[shareKey] += shares;

        // Track asset-share proportionality for share issuance
        // Track shares issued for deposits - need to iterate through tracked assets for this pool/shareClass
        AssetId[] memory assets = _getAssetIds();
        for (uint256 i = 0; i < assets.length; i++) {
            bytes32 assetKey = keccak256(abi.encode(poolId, scId, assets[i]));
            // If this asset has proportionality tracking enabled, update cumulative shares
            if (ghost_depositProportionalityTracked[assetKey]) {
                ghost_cumulativeSharesIssuedForDeposits[assetKey] += shares;
            }
        }

        balanceSheet.issue(poolId, scId, _getActor(), shares);

        issuedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] += shares;

        // Update ghost variables
        ghost_totalIssued[shareKey] += shares;
        ghost_netSharePosition[shareKey] += int256(uint256(shares));

        // Check for share queue flip based on actual queue state changes
        (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(poolId, scId);
        bytes32 key = _poolShareKey(poolId, scId);
        uint128 deltaBefore = before_shareQueueDelta[key];
        bool isPositiveBefore = before_shareQueueIsPositive[key];

        // Detect flip in queue state (replaces ghost position flip detection)
        bool queueFlipOccurred = (isPositiveBefore != isPositiveAfter) && (deltaBefore != 0 || deltaAfter != 0);
        if (queueFlipOccurred) {
            ghost_flipCount[shareKey]++;
        }
    }

    /// @dev Property: PoolEscrow.total increases by exactly the amount deposited
    /// @dev Property: PoolEscrow.reserved does not change during noteDeposit
    /// @notice Direct BalanceSheet operation that updates PoolEscrow. Mirrors noteDeposit's real-world
    ///         use case (reconciling assets that already reached the escrow via donation/accidental
    ///         transfer) by minting the matching amount to the escrow first, so the fuzzer explores the
    ///         intended usage rather than the documented admin over-crediting footgun.
    function balanceSheet_noteDeposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeV3_1_0.vaultDetails(vault).assetId;
        address asset = vault.asset();

        // Track authorization - noteDeposit() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        IPoolEscrow poolEscrow = poolEscrowFactory.escrow(poolId);
        (uint128 totalBefore, uint128 reservedBefore) = PoolEscrow(address(poolEscrow)).holding(scId, asset, tokenId);

        if (tokenId == 0) MockERC20(asset).mint(address(poolEscrow), amount);

        balanceSheet.noteDeposit(poolId, scId, asset, tokenId, amount);

        (uint128 totalAfter, uint128 reservedAfter) = PoolEscrow(address(poolEscrow)).holding(scId, asset, tokenId);
        t(totalAfter == totalBefore + amount, "balanceSheet_noteDeposit: PoolEscrow.total should increase by amount");
        t(reservedAfter == reservedBefore, "balanceSheet_noteDeposit: PoolEscrow.reserved should not change");

        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));
        ghost_assetQueueDeposits[assetKey] += amount;
    }

    struct WithdrawReservedState {
        uint128 total;
        uint128 reserved;
        uint128 deposits;
        uint128 withdrawals;
    }

    /// @dev Property: PoolEscrow.total and PoolEscrow.reserved both decrease by exactly the amount withdrawn
    /// @dev Property: withdrawReserved does not queue a Hub holding decrease (already queued when reserved)
    function balanceSheet_withdrawReserved(uint256 tokenId, uint128 amount) public updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Track authorization - withdrawReserved() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        WithdrawReservedState memory before_ = _captureWithdrawReservedState(vault, tokenId);

        // NOTE: Only REASON_DEPOSIT/asyncRequestManager reservations are reachable here (see balanceSheet_reserve).
        try balanceSheet.withdrawReserved(
            poolId, scId, vault.asset(), tokenId, _getActor(), amount, address(asyncRequestManager), REASON_DEPOSIT
        ) {
            _checkWithdrawReservedSuccess(vault, tokenId, amount, before_);
        } catch {}
    }

    function _captureWithdrawReservedState(IBaseVault vault, uint256 tokenId)
        private
        view
        returns (WithdrawReservedState memory state)
    {
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        address asset = vault.asset();
        AssetId assetId = spokeV3_1_0.vaultDetails(vault).assetId;

        IPoolEscrow poolEscrow = poolEscrowFactory.escrow(poolId);
        (state.total, state.reserved) = PoolEscrow(address(poolEscrow)).holding(scId, asset, tokenId);
        (state.deposits, state.withdrawals) = balanceSheet.queuedAssets(poolId, scId, assetId);
    }

    function _checkWithdrawReservedSuccess(
        IBaseVault vault,
        uint256 tokenId,
        uint128 amount,
        WithdrawReservedState memory before_
    ) private {
        address asset = vault.asset();
        WithdrawReservedState memory after_ = _captureWithdrawReservedState(vault, tokenId);

        t(
            after_.total == before_.total - amount,
            "balanceSheet_withdrawReserved: PoolEscrow.total should decrease by amount"
        );
        t(
            after_.reserved == before_.reserved - amount,
            "balanceSheet_withdrawReserved: PoolEscrow.reserved should decrease by amount"
        );
        eq(after_.deposits, before_.deposits, "balanceSheet_withdrawReserved: queued deposits should not change");
        eq(
            after_.withdrawals,
            before_.withdrawals,
            "balanceSheet_withdrawReserved: queued withdrawals should not change"
        );

        bytes32 key = keccak256(abi.encode(vault.poolId(), vault.scId(), spokeV3_1_0.vaultDetails(vault).assetId));
        if (ghost_netReserved[key] >= amount) ghost_netReserved[key] -= amount;
        sumOfManagerWithdrawals[asset] += amount;
    }

    /// @dev Property: withdrawShares moves shares out of the pool escrow with no change to queuedShares
    function balanceSheet_withdrawShares(uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Track authorization - withdrawShares() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        address shareToken = vault.share();
        address poolEscrowAddr = _getPoolEscrowForVault(vault);
        uint256 escrowBefore = IShareToken(shareToken).balanceOf(poolEscrowAddr);
        uint256 receiverBefore = IShareToken(shareToken).balanceOf(_getActor());
        (uint128 deltaBefore, bool isPositiveBefore,,) = balanceSheet.queuedShares(poolId, scId);

        try balanceSheet.withdrawShares(poolId, scId, _getActor(), amount) {
            uint256 escrowAfter = IShareToken(shareToken).balanceOf(poolEscrowAddr);
            uint256 receiverAfter = IShareToken(shareToken).balanceOf(_getActor());
            (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(poolId, scId);

            t(
                escrowBefore - escrowAfter == amount,
                "balanceSheet_withdrawShares: PoolEscrow share balance should decrease by amount"
            );
            t(
                receiverAfter - receiverBefore == amount,
                "balanceSheet_withdrawShares: receiver share balance should increase by amount"
            );
            eq(deltaAfter, deltaBefore, "balanceSheet_withdrawShares: queuedShares delta should not change");
            t(
                isPositiveAfter == isPositiveBefore,
                "balanceSheet_withdrawShares: queuedShares isPositive should not change"
            );
        } catch {}
    }

    function balanceSheet_recoverTokens(address token, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, _getActor(), amount);
    }

    function balanceSheet_recoverTokens(address token, uint256 tokenId, uint256 amount) public updateGhosts asActor {
        balanceSheet.recoverTokens(token, tokenId, _getActor(), amount);
    }

    // NOTE: removed because introduces false positives
    // function balanceSheet_rely() public updateGhosts asActor {
    //     // Track authorization - rely() requires auth (ward only)
    //     _trackAuthorization(_getActor(), PoolId.wrap(0)); // Global operation, use PoolId 0
    //     _checkAndRecordAuthChange(_getActor()); // Track auth changes from rely()

    //     balanceSheet.rely(_getActor());
    // }

    function balanceSheet_revoke(uint128 shares) public updateGhosts asActor {
        IBaseVault vault = _getVault();
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        _captureShareQueueState(poolId, scId);

        // Track authorization - revoke() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track for property iteration
        // _trackPoolAndShareClass(poolId, scId);

        // Track previous net position for flip detection
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));

        // Track supply operations
        ghost_supplyOperationOccurred[shareKey] = true;
        ghost_totalShareSupply[shareKey] -= shares;
        ghost_supplyBurnEvents[shareKey] += shares;

        // Track share revocation for withdrawals
        // Track shares revoked for all assets in this pool/shareClass
        AssetId[] memory assets = _getAssetIds();
        for (uint256 i = 0; i < assets.length; i++) {
            bytes32 assetKey = keccak256(abi.encode(poolId, scId, assets[i]));
            // If withdrawal proportionality tracking is enabled for this asset, update cumulative shares
            if (ghost_withdrawalProportionalityTracked[assetKey]) {
                ghost_cumulativeSharesRevokedForWithdrawals[assetKey] += shares;
            }
        }

        balanceSheet.revoke(poolId, scId, shares);

        revokedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] -= shares;

        // Update ghost variables
        ghost_totalRevoked[shareKey] += shares;
        ghost_netSharePosition[shareKey] -= int256(uint256(shares));

        // Check for share queue flip based on actual queue state changes
        (uint128 deltaAfter, bool isPositiveAfter,,) = balanceSheet.queuedShares(poolId, scId);
        bytes32 key = _poolShareKey(poolId, scId);
        uint128 deltaBefore = before_shareQueueDelta[key];
        bool isPositiveBefore = before_shareQueueIsPositive[key];

        // Detect flip in queue state (replaces ghost position flip detection)
        bool queueFlipOccurred = (isPositiveBefore != isPositiveAfter) && (deltaBefore != 0 || deltaAfter != 0);
        if (queueFlipOccurred) {
            ghost_flipCount[shareKey]++;
        }
    }

    // NOTE: removed because introduces false positives when checking actor share balances
    // function balanceSheet_transferSharesFrom(
    //     address to,
    //     uint256 amount
    // ) public updateGhosts asActor {
    //     IBaseVault vault = IBaseVault(_getVault());
    //     PoolId poolId = vault.poolId();
    //     ShareClassId scId = vault.scId();
    //     _captureShareQueueState(poolId, scId);

    //     // Track authorization - transferSharesFrom() requires authOrManager(poolId)
    //     _trackAuthorization(_getActor(), poolId);

    //     // Track endorsement status before transfer
    //     address from = _getActor();
    //     address recipient = _getRandomActor(uint256(uint160(to)));
    //     _trackEndorsedTransfer(from, recipient, poolId, scId);

    //     bytes32 key = keccak256(abi.encode(poolId, scId));

    //     // Attempt the transfer - will revert if from is endorsed
    //     try
    //         balanceSheet.transferSharesFrom(
    //             poolId,
    //             scId,
    //             from,
    //             from,
    //             recipient,
    //             amount
    //         )
    //     {
    //         // Transfer succeeded - track as valid
    //         ghost_validTransferCount[key]++;

    //         // Track balance changes for transfers (supply stays same, only balances shift)
    //         ghost_supplyOperationOccurred[key] = true;
    //     } catch {
    //         // Transfer failed - likely due to endorsement restriction
    //         if (_isEndorsedContract(from)) {
    //             ghost_blockedEndorsedTransfers[key]++;
    //         }
    //     }
    // }

    /// @dev Property: Withdrawals should not fail when there's sufficient balance
    function balanceSheet_withdraw(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeV3_1_0.vaultDetails(vault).assetId;
        _captureShareQueueState(poolId, scId);

        // Track authorization - withdraw() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));

        // Track escrow balance sufficiency
        ghost_escrowSufficiencyTracked[assetKey] = true;

        try balanceSheet.withdraw(poolId, scId, vault.asset(), tokenId, _getActor(), amount) {
            // Successful withdrawal
            uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
            ghost_escrowAvailableBalance[assetKey] = newAvailable;
            ghost_escrowReservedBalance[assetKey] = ghost_netReserved[assetKey];

            // Track withdrawal proportionality
            ghost_withdrawalProportionalityTracked[assetKey] = true;
            ghost_cumulativeAssetsWithdrawn[assetKey] += amount;
            ghost_assetQueueWithdrawals[assetKey] += amount;
            sumOfManagerWithdrawals[vault.asset()] += amount;
        } catch {
            // NOTE: removed because admin can easily cause this to fail
            // bool expectedError = checkError(err, Panic.arithmeticPanic); // we care about reverts due to arithmetic errors
            // // Check if withdrawal was possible with available balance (track failures)
            // if (expectedError && amount <= prevAvailable) {
            //     t(false, "Withdrawals failed despite sufficient balance");
            // }
        }
    }

    // ===============================
    // QUEUE OPERATIONS
    // ===============================

    /// @dev Property
    function balanceSheet_reserve(uint256 tokenId, uint128 amount) public updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeV3_1_0.vaultDetails(vault).assetId;

        // Track authorization - reserve() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        bytes32 key = keccak256(abi.encode(poolId, scId, assetId));

        // Track reserve operations
        ghost_totalReserveOperations[key]++;

        // NOTE: Only REASON_DEPOSIT exposed. REASON_REDEEM is covered via lifecycle shortcuts
        // (e.g., shortcut_redeem_and_claim_clamped) which go through AsyncRequestManager.
        // Adding REASON_REDEEM here would double the admin-mistake false positive surface
        // (Issue #10) without new protocol insight.
        try balanceSheet.reserve(
            poolId, scId, vault.asset(), tokenId, amount, address(asyncRequestManager), REASON_DEPOSIT
        ) {
            if (ghost_netReserved[key] <= type(uint256).max - amount) {
                ghost_netReserved[key] += amount;
            }

            // Track escrow balance sufficiency
            ghost_escrowSufficiencyTracked[key] = true;
            uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
            ghost_escrowAvailableBalance[key] = newAvailable;
            ghost_escrowReservedBalance[key] = ghost_netReserved[key];
        } catch (bytes memory err) {
            bool overflowRevert = checkError(err, Panic.arithmeticPanic);

            // Core Invariant 4: No overflow occurred
            if (ghost_netReserved[key] > type(uint256).max - amount) {
                t(!overflowRevert, "Reserve operation caused overflow");
            }
        }
    }

    /// @dev Clamped reserve: bounds amount to available escrow balance
    function balanceSheet_reserve_clamped(uint128 amount) public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        uint128 available = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), 0);
        amount = uint128(uint256(amount) % (uint256(available) + 1));
        balanceSheet_reserve(0, amount);
    }

    /// @dev Property: unreserve causes an underflow revert
    function balanceSheet_unreserve(uint256 tokenId, uint128 amount) public updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeV3_1_0.vaultDetails(vault).assetId;

        // Track authorization - unreserve() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        bytes32 key = keccak256(abi.encode(poolId, scId, assetId));

        // Track unreserve operations
        ghost_totalUnreserveOperations[key]++;

        // NOTE: Only REASON_DEPOSIT exposed. REASON_REDEEM is covered via lifecycle shortcuts
        // (e.g., shortcut_redeem_and_claim_clamped) which go through AsyncRequestManager.
        // Adding REASON_REDEEM here would double the admin-mistake false positive surface
        // (Issue #10) without new protocol insight.
        try balanceSheet.unreserve(
            poolId, scId, vault.asset(), tokenId, amount, address(asyncRequestManager), REASON_DEPOSIT
        ) {
            if (ghost_netReserved[key] >= amount) {
                ghost_netReserved[key] -= amount;
            }

            // Track escrow balance sufficiency
            ghost_escrowSufficiencyTracked[key] = true;
            uint128 newAvailable = balanceSheet.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
            ghost_escrowAvailableBalance[key] = newAvailable;
            ghost_escrowReservedBalance[key] = ghost_netReserved[key];
        } catch (bytes memory err) {
            bool underflowRevert = checkError(err, Panic.arithmeticPanic);

            if (ghost_netReserved[key] < amount) {
                // Core Invariant 5: No underflow occurred
                t(!underflowRevert, "Unreserve operation caused underflow");
            }
        }
    }

    function balanceSheet_submitQueuedAssets(uint128 extraGasLimit) public updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeV3_1_0.vaultDetails(vault).assetId;

        // Track authorization - submitQueuedAssets() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track nonce monotonicity for Queue State Consistency properties
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));

        // Get current nonce to track monotonicity
        (,,, uint64 currentNonce) = balanceSheet.queuedShares(poolId, scId);
        ghost_previousNonce[shareKey] = currentNonce;

        balanceSheet.submitQueuedAssets(poolId, scId, assetId, extraGasLimit, address(this));
    }

    function balanceSheet_submitQueuedShares(uint128 extraGasLimit) public updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        _captureShareQueueState(poolId, scId);

        // Track authorization - submitQueuedShares() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track nonce monotonicity for Queue State Consistency properties
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));

        // Get current nonce to track monotonicity
        (,,, uint64 currentNonce) = balanceSheet.queuedShares(poolId, scId);
        ghost_previousNonce[shareKey] = currentNonce;

        ghost_shareQueueNonce[shareKey]++;

        balanceSheet.submitQueuedShares{value: 0.1 ether}(poolId, scId, extraGasLimit, address(this));

        // Reset ghost_netSharePosition to match the cleared queue state
        // After submitQueuedShares, the BalanceSheet contract resets delta=0 and isPositive=false
        ghost_netSharePosition[shareKey] = 0;
        ghost_totalIssued[shareKey] = 0;
        ghost_totalRevoked[shareKey] = 0;
    }
}
