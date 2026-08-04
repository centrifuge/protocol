// SPDX-License-Identifier: GPL-2.0
pragma solidity ^0.8.0;

import {D18, d18} from "../../../../src/misc/types/D18.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {PoolEscrow} from "../../../../src/core/spoke/PoolEscrow.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";

import {IBaseVault} from "../../../../src/vaults/interfaces/IBaseVault.sol";
import {REASON_DEPOSIT} from "../../../../src/vaults/interfaces/IVaultManagers.sol";

import {Panic} from "@recon/Panic.sol";
import {Helpers} from "../utils/Helpers.sol";
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

    //     spoke.deny(_getActor());
    // }

    function balanceSheet_deposit(uint256 tokenId, uint128 amount) public updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeRegistry.vaultDetails(address(vault)).assetId;
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

        spoke.deposit(poolId, scId, vault.asset(), tokenId, amount);

        sumOfManagerDeposits[vault.asset()] += amount;

        // Update escrow tracking: total balance increases by deposit amount
        uint128 newAvailable = spoke.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
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

        spoke.issue(poolId, scId, _getActor(), shares);

        issuedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] += shares;

        // Update ghost variables
        ghost_totalIssued[shareKey] += shares;
        ghost_netSharePosition[shareKey] += int256(uint256(shares));

        // Check for share queue flip based on actual queue state changes
        (uint128 deltaAfter, bool isPositiveAfter,,) = snapshotQueue.queuedShares(poolId, scId);
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
        address asset = vault.asset();

        // Track authorization - noteDeposit() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        IPoolEscrow poolEscrow = poolEscrowFactory.escrow(poolId);
        (uint128 totalBefore, uint128 reservedBefore) = PoolEscrow(address(poolEscrow)).holding(scId, asset, tokenId);

        if (tokenId == 0) {
            MockERC20(asset).mint(address(poolEscrow), amount);
            // noteDeposit credits the escrow the same way balanceSheet_deposit does, so it belongs in the
            // same conservation-inflow ghost.
            sumOfManagerDeposits[asset] += amount;
        }

        spoke.noteDeposit(poolId, scId, asset, tokenId, amount);

        (uint128 totalAfter, uint128 reservedAfter) = PoolEscrow(address(poolEscrow)).holding(scId, asset, tokenId);
        t(totalAfter == totalBefore + amount, "balanceSheet_noteDeposit: PoolEscrow.total should increase by amount");
        t(reservedAfter == reservedBefore, "balanceSheet_noteDeposit: PoolEscrow.reserved should not change");
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
        try spoke.withdrawReserved(
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
        AssetId assetId = spokeRegistry.vaultDetails(address(vault)).assetId;

        IPoolEscrow poolEscrow = poolEscrowFactory.escrow(poolId);
        (state.total, state.reserved) = PoolEscrow(address(poolEscrow)).holding(scId, asset, tokenId);
        (state.deposits, state.withdrawals) = snapshotQueue.queuedAssets(poolId, scId, assetId);
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

        bytes32 key =
            keccak256(abi.encode(vault.poolId(), vault.scId(), spokeRegistry.vaultDetails(address(vault)).assetId));
        if (ghost_netReserved[key] >= amount) ghost_netReserved[key] -= amount;
        sumOfManagerWithdrawals[asset] += amount;
    }

    /// @dev Internal only: unbounded amounts strand notified claims by pulling claim-backing shares from escrow
    /// @dev Property: withdrawShares moves shares out of the pool escrow with no change to queuedShares
    function balanceSheet_withdrawShares(uint128 amount) internal updateGhosts asActor {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        // Track authorization - withdrawShares() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        address shareToken = vault.share();
        address poolEscrowAddr = _getPoolEscrowForVault(vault);
        uint256 escrowBefore = IShareToken(shareToken).balanceOf(poolEscrowAddr);
        uint256 receiverBefore = IShareToken(shareToken).balanceOf(_getActor());
        (uint128 deltaBefore, bool isPositiveBefore,,) = snapshotQueue.queuedShares(poolId, scId);

        try spoke.withdrawShares(poolId, scId, _getActor(), amount) {
            uint256 escrowAfter = IShareToken(shareToken).balanceOf(poolEscrowAddr);
            uint256 receiverAfter = IShareToken(shareToken).balanceOf(_getActor());
            (uint128 deltaAfter, bool isPositiveAfter,,) = snapshotQueue.queuedShares(poolId, scId);

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

    /// @dev Bounds amount to the escrow's share free float (balance minus Σ(maxMint + pending redeem + claimable
    ///      cancel-redeem shares)), so a withdrawal can never strand a notified deposit claim, an in-flight redeem,
    ///      or a claimable cancel-redeem.
    /// @dev maxMint backing is async-only (sync deposits claim immediately), but redeem-side shares back claims on
    ///      BOTH vault types (the redeem side is always async), so those terms are unconditional.
    /// @dev Pending redeem shares must be reserved too: `cancelRedeemRequest` turns them into a claimable
    ///      cancel-redeem without moving any shares, so reserving only the claimable side leaves the window before
    ///      the cancel unguarded.
    /// @dev The escrow is per-poolId and SpokeRegistry permits several vaults on one (poolId, scId, asset), so a
    ///      budget derived from the cursor vault alone lets a withdrawal clamped to one vault's backing drain the
    ///      escrow behind another's claims. The reserve therefore spans every vault on the share class.
    function balanceSheet_withdrawShares_clamped(uint128 amount) public {
        IBaseVault vault = IBaseVault(_getVault());
        uint256 escrowShares = IShareToken(vault.share()).balanceOf(_getPoolEscrowForVault(vault));

        uint256 claimBacking = _shareClassClaimBacking(vault);
        uint256 freeFloat = escrowShares > claimBacking ? escrowShares - claimBacking : 0;

        // Cap at the manager's own net issuance. Escrow shares minted by a deposit approval back a claim that only
        // materializes at notifyDeposit, so a budget derived from existing claims alone still lets a withdrawal
        // front-run the notify. Bounding to what the manager itself issued reserves those shares without
        // reimplementing the hub's per-epoch issuance math here.
        uint256 managerFloat = shareMints[vault.share()];
        uint256 budget = freeFloat < managerFloat ? freeFloat : managerFloat;

        amount = uint128(uint256(amount) % (budget + 1));
        balanceSheet_withdrawShares(amount);
    }

    /// @dev Shares in the pool escrow that back an outstanding claim on ANY vault of `cursor`'s share class.
    /// @dev maxMint backing is async-only (sync deposits claim immediately), but redeem-side shares back claims on
    ///      BOTH vault types (the redeem side is always async), so those terms are unconditional.
    function _shareClassClaimBacking(IBaseVault cursor) internal view returns (uint256 claimBacking) {
        PoolId poolId = cursor.poolId();
        ShareClassId scId = cursor.scId();
        address[] memory actors = _getActors();
        IBaseVault[] memory vaults = _getVaults();

        for (uint256 v; v < vaults.length; v++) {
            IBaseVault vault = vaults[v];
            if (!(poolId == vault.poolId()) || !(scId == vault.scId())) continue;

            bool isAsync = Helpers.isAsyncVault(address(vault));
            for (uint256 i; i < actors.length; i++) {
                if (isAsync) {
                    try vault.maxMint(actors[i]) returns (uint256 shareAmt) {
                        claimBacking += shareAmt;
                    } catch {}
                }
                try asyncRequestManager.pendingRedeemRequest(vault, actors[i]) returns (uint256 shareAmt) {
                    claimBacking += shareAmt;
                } catch {}
                try asyncRequestManager.claimableCancelRedeemRequest(vault, actors[i]) returns (uint256 shareAmt) {
                    claimBacking += shareAmt;
                } catch {}
            }
        }
    }

    function balanceSheet_recoverTokens(address token, uint256 amount) public updateGhosts asActor {
        spoke.recoverTokens(token, _getActor(), amount);
    }

    function balanceSheet_recoverTokens(address token, uint256 tokenId, uint256 amount) public updateGhosts asActor {
        spoke.recoverTokens(token, tokenId, _getActor(), amount);
    }

    // NOTE: removed because introduces false positives
    // function balanceSheet_rely() public updateGhosts asActor {
    //     // Track authorization - rely() requires auth (ward only)
    //     _trackAuthorization(_getActor(), PoolId.wrap(0)); // Global operation, use PoolId 0
    //     _checkAndRecordAuthChange(_getActor()); // Track auth changes from rely()

    //     spoke.rely(_getActor());
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

        spoke.revoke(poolId, scId, shares);

        revokedBalanceSheetShares[poolId][scId] += shares;
        shareMints[vault.share()] -= shares;

        // Update ghost variables
        ghost_totalRevoked[shareKey] += shares;
        ghost_netSharePosition[shareKey] -= int256(uint256(shares));

        // Check for share queue flip based on actual queue state changes
        (uint128 deltaAfter, bool isPositiveAfter,,) = snapshotQueue.queuedShares(poolId, scId);
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
    //         spoke.transferSharesFrom(
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
        AssetId assetId = spokeRegistry.vaultDetails(address(vault)).assetId;
        _captureShareQueueState(poolId, scId);

        // Track authorization - withdraw() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Update queue ghost variables
        bytes32 assetKey = keccak256(abi.encode(poolId, scId, assetId));

        // Track escrow balance sufficiency
        ghost_escrowSufficiencyTracked[assetKey] = true;

        try spoke.withdraw(poolId, scId, vault.asset(), tokenId, _getActor(), amount) {
            // Successful withdrawal
            uint128 newAvailable = spoke.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
            ghost_escrowAvailableBalance[assetKey] = newAvailable;
            ghost_escrowReservedBalance[assetKey] = ghost_netReserved[assetKey];

            // Track withdrawal proportionality
            ghost_withdrawalProportionalityTracked[assetKey] = true;
            ghost_cumulativeAssetsWithdrawn[assetKey] += amount;
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

    /// @dev Internal only: unbounded reserve amounts reopen the admin-mistake DOS surface, so use the clamped variants
    function balanceSheet_reserve(uint256 tokenId, uint128 amount) internal updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeRegistry.vaultDetails(address(vault)).assetId;

        // Track authorization - reserve() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        bytes32 key = keccak256(abi.encode(poolId, scId, assetId));

        // NOTE: Only REASON_DEPOSIT exposed. REASON_REDEEM is covered via lifecycle shortcuts
        // (e.g., shortcut_redeem_and_claim_clamped) which go through AsyncRequestManager; exposing it here
        // would only widen the admin-mistake false positive surface.
        try spoke.reserve(poolId, scId, vault.asset(), tokenId, amount, address(asyncRequestManager), REASON_DEPOSIT) {
            if (ghost_netReserved[key] <= type(uint256).max - amount) {
                ghost_netReserved[key] += amount;
            }

            // Track escrow balance sufficiency
            ghost_escrowSufficiencyTracked[key] = true;
            uint128 newAvailable = spoke.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
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
        uint128 available = spoke.availableBalanceOf(poolId, scId, vault.asset(), 0);
        amount = uint128(uint256(amount) % (uint256(available) + 1));
        balanceSheet_reserve(0, amount);
    }

    /// @dev Deliberately over-reserves (reserved > total) to drive bounded escrow deficit excursions
    function balanceSheet_overReserve_clamped(uint128 amount) public {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        uint128 available = spoke.availableBalanceOf(poolId, scId, vault.asset(), 0);
        amount = uint128(uint256(available) + 1 + (uint256(amount) % (uint256(available) + 1)));
        balanceSheet_reserve(0, amount);
    }

    /// @dev Property: unreserve causes an underflow revert
    /// @dev `internal` (reproducer-only), mirroring `balanceSheet_reserve`: unreserving more than is reserved
    ///      underflows trivially, so only the clamped variant is on the fuzzer surface.
    function balanceSheet_unreserve(uint256 tokenId, uint128 amount) internal updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeRegistry.vaultDetails(address(vault)).assetId;

        // Track authorization - unreserve() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        bytes32 key = keccak256(abi.encode(poolId, scId, assetId));

        // NOTE: Only REASON_DEPOSIT exposed. REASON_REDEEM is covered via lifecycle shortcuts
        // (e.g., shortcut_redeem_and_claim_clamped) which go through AsyncRequestManager; exposing it here
        // would only widen the admin-mistake false positive surface.
        try spoke.unreserve(
            poolId, scId, vault.asset(), tokenId, amount, address(asyncRequestManager), REASON_DEPOSIT
        ) {
            if (ghost_netReserved[key] >= amount) {
                ghost_netReserved[key] -= amount;
            }

            // Track escrow balance sufficiency
            ghost_escrowSufficiencyTracked[key] = true;
            uint128 newAvailable = spoke.availableBalanceOf(poolId, scId, vault.asset(), tokenId);
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

    /// @dev Bounds amount to what is actually reserved, so the fuzzer exercises unreserve instead of the underflow
    ///      that any over-unreserve trivially produces.
    function balanceSheet_unreserve_clamped(uint128 amount) public {
        IBaseVault vault = IBaseVault(_getVault());
        bytes32 key =
            keccak256(abi.encode(vault.poolId(), vault.scId(), spokeRegistry.vaultDetails(address(vault)).assetId));

        amount = uint128(uint256(amount) % (ghost_netReserved[key] + 1));
        balanceSheet_unreserve(0, amount);
    }

    function balanceSheet_submitQueuedAssets(uint128 extraGasLimit) public updateGhosts asAdmin {
        IBaseVault vault = IBaseVault(_getVault());
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        AssetId assetId = spokeRegistry.vaultDetails(address(vault)).assetId;

        // Track authorization - submitQueuedAssets() requires isManager(poolId)
        _trackAuthorization(_getActor(), poolId);

        // Track nonce monotonicity for Queue State Consistency properties
        bytes32 shareKey = keccak256(abi.encode(poolId, scId));

        // Get current nonce to track monotonicity
        (,,, uint64 currentNonce) = snapshotQueue.queuedShares(poolId, scId);
        ghost_previousNonce[shareKey] = currentNonce;

        spoke.submitQueuedAssets(poolId, scId, assetId, extraGasLimit, address(this));

        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(poolId, scId, assetId);
        eq(uint256(deposits), 0, "submitQueuedAssets: queued deposits not flushed to 0");
        eq(uint256(withdrawals), 0, "submitQueuedAssets: queued withdrawals not flushed to 0");
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
        (,,, uint64 currentNonce) = snapshotQueue.queuedShares(poolId, scId);
        ghost_previousNonce[shareKey] = currentNonce;

        ghost_shareQueueNonce[shareKey]++;

        spoke.submitQueuedShares{value: 0.1 ether}(poolId, scId, extraGasLimit, address(this));

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(poolId, scId);
        eq(uint256(delta), 0, "submitQueuedShares: queued share delta not flushed to 0");
        t(!isPositive, "submitQueuedShares: queued share isPositive not reset");

        // Reset ghost_netSharePosition to match the cleared queue state
        // After submitQueuedShares, the BalanceSheet contract resets delta=0 and isPositive=false
        ghost_netSharePosition[shareKey] = 0;
        ghost_totalIssued[shareKey] = 0;
        ghost_totalRevoked[shareKey] = 0;
    }
}
