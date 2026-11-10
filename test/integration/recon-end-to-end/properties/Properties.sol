// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FeeProperties} from "./FeeProperties.sol";
import {CustodyProperties} from "./CustodyProperties.sol";
import {GasBoundProperties} from "./GasBoundProperties.sol";
import {InstantLaneProperties} from "./InstantLaneProperties.sol";
import {ConservationProperties} from "./ConservationProperties.sol";

import {D18} from "../../../../src/misc/types/D18.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IEscrow} from "../../../../src/core/spoke/interfaces/IEscrow.sol";

import {BucketReference} from "../../../vaults/BucketReference.sol";

import {IAsyncVault, IVaultErrors, Bucket, REASON_REDEEM} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {OpType} from "../BeforeAfter.sol";

/// @notice The standing properties. Each is a public `property_*` function, so Echidna and Medusa call
///         them in assertion mode and the Foundry entrypoint calls them from its invariant. Names carried
///         over from the suite this replaces are kept, so the specification can keep citing them.
abstract contract Properties is
    ConservationProperties,
    InstantLaneProperties,
    CustodyProperties,
    FeeProperties,
    GasBoundProperties
{
    //----------------------------------------------------------------------------------------------
    // Share token
    //----------------------------------------------------------------------------------------------

    /// @dev Every pool A share sits with a tracked holder: the investors, the escrow, or the managers the
    ///      fuzzer lets hold them. Vaults only route shares through themselves within a call.
    function property_sum_of_balances() public {
        address[] memory holders = _shareHolders();
        uint256 sum;
        for (uint256 i; i < holders.length; i++) {
            sum += shareA.balanceOf(holders[i]);
        }
        eq(sum, shareA.totalSupply(), "sum of tracked balances != totalSupply");
    }

    /// @dev Supply consistency on every pool, including the two the fuzzer only reaches indirectly.
    function property_shareTokenSupplyConsistency() public {
        property_sum_of_balances();
        eq(
            shareB.totalSupply(),
            shareB.balanceOf(INVESTOR_B) + shareB.balanceOf(address(_escrow(poolB))),
            "pool B supply outside its holders"
        );
        eq(
            shareC.totalSupply(),
            shareC.balanceOf(address(_escrow(poolA))) + shareC.balanceOf(address(_escrow(poolC)))
                + shareC.balanceOf(BSM) + shareC.balanceOf(AUX_MANAGER),
            "pool C supply outside its holders"
        );
    }

    /// @dev A share class with supply always resolves to its token, so supply is never orphaned.
    function property_shareTokenCountedInSupply() public {
        t(address(spokeRegistry.shareToken(poolA, scA)) == address(shareA), "pool A share token unregistered");
        t(address(spokeRegistry.shareToken(poolC, scC)) == address(shareC), "pool C share token unregistered");
        t(address(spokeRegistry.shareToken(poolB, scB)) == address(shareB), "pool B share token unregistered");
    }

    function property_system_addresses_never_receive_share_tokens() public {
        address[13] memory system = [
            address(spoke),
            address(hub),
            address(shareTokenRegistrar),
            address(vaultFactory),
            address(vaultRouter),
            address(orderBook),
            address(feeRequestManager),
            address(vaultRoute),
            address(basinRoute),
            address(reserveInstantPolicy),
            address(fullRestrictions),
            address(gateway),
            address(this)
        ];
        for (uint256 i; i < system.length; i++) {
            eq(shareA.balanceOf(system[i]), 0, "a system address holds pool A shares");
        }
        for (uint256 i; i < vaults.length; i++) {
            eq(shareA.balanceOf(address(vaults[i])), 0, "a vault holds pool A shares between calls");
            eq(usdc.balanceOf(address(vaults[i])), 0, "a vault holds assets between calls");
        }
    }

    /// @dev USDC is closed over the actors, the managers, the escrows, the venue, its liquidity provider and
    ///      the instant lane's fee recipient: nothing the fuzzer does sends it anywhere else.
    function property_everyAssetIsAccountedFor() public {
        uint256 sum = usdc.balanceOf(address(_escrow(poolA))) + usdc.balanceOf(address(_escrow(poolB)))
            + usdc.balanceOf(address(_escrow(poolC))) + usdc.balanceOf(BSM) + usdc.balanceOf(INVESTOR_B)
            + usdc.balanceOf(address(_escrow(poolD))) + usdc.balanceOf(INVESTOR_D) + usdc.balanceOf(address(basin))
            + usdc.balanceOf(LP) + usdc.balanceOf(FEE_RECIPIENT) + usdc.balanceOf(AUX_MANAGER)
            + usdc.balanceOf(OUTSIDER) + usdc.balanceOf(REBATER);
        for (uint256 i; i < actors.length; i++) {
            sum += usdc.balanceOf(actors[i]);
        }
        eq(usdc.totalSupply(), sum, "assets leaked to an untracked address");
    }

    //----------------------------------------------------------------------------------------------
    // Escrow
    //----------------------------------------------------------------------------------------------

    /// @dev Each escrow's raw balance of a holding asset equals the sum of `holding.total` across its
    ///      share classes (one per pool here), plus what was sent to pool A's escrow without being booked.
    function property_escrowBalanceMatchesHoldingTotal() public {
        PoolId[3] memory pools = [poolA, poolB, poolC];
        for (uint256 p; p < pools.length; p++) {
            IEscrow escrow = _escrow(pools[p]);
            (uint128 total,) = escrow.holding(_scOf(pools[p]), address(usdc), 0);
            uint256 donated = pools[p].raw() == poolA.raw() ? ghost_donatedToEscrow : 0;
            eq(usdc.balanceOf(address(escrow)), total + donated, "escrow USDC balance != holding total");
        }
        (uint128 cTotal,) = _escrow(poolA).holding(scA, address(shareC), 0);
        eq(shareC.balanceOf(address(_escrow(poolA))), cTotal, "escrow pool C share balance != holding total");
    }

    /// @dev What the basin vault owes the venue is on pool A's balance sheet: the liability tokens in the
    ///      escrow are its receivable, from the draw until the repayment.
    function property_basinDebtIsBooked() public {
        (uint128 booked,) = _escrow(poolA).holding(scA, address(accountingToken), _basinLiabilityTokenId());
        eq(booked, basinRoute.receivable(address(vaults[3])), "booked liability != basin receivable");
        eq(
            accountingToken.balanceOf(address(_escrow(poolA)), _basinLiabilityTokenId()),
            booked,
            "escrow liability balance != holding total"
        );
    }

    /// @dev Holdings conservation: once an asset queue is drained, the hub's holding amount is the
    ///      escrow's accounted balance, `total - reserved` floored at zero, exactly.
    function property_hubHoldingMatchesEscrowAccounted() public {
        _checkHoldingMatches(poolA, scA, usdcId, address(usdc));
        _checkHoldingMatches(poolA, scA, cShareId, address(shareC));
        _checkHoldingMatches(poolB, scB, usdcId, address(usdc));
        _checkHoldingMatches(poolC, scC, usdcId, address(usdc));
    }

    function _checkHoldingMatches(PoolId poolId, ShareClassId scId, AssetId assetId, address asset) internal {
        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(poolId, scId, assetId);
        if (deposits != 0 || withdrawals != 0) return;
        (uint128 total, uint128 reserved) = _escrow(poolId).holding(scId, asset, 0);
        uint128 accounted = total > reserved ? total - reserved : 0;
        eq(holdings.amount(poolId, scId, assetId), accounted, "hub holding != escrow accounted");
    }

    /// @dev Pool A's USDC reservations are exactly the vaults' per-request deposit reasons, their redeem
    ///      reasons and the balance-sheet manager's own bucket: nothing is reserved under an unknown key.
    function property_escrowReservedSumConsistency() public {
        IEscrow escrow = _escrow(poolA);
        (, uint128 reserved) = escrow.holding(scA, address(usdc), 0);
        uint256 sum = ghost_bsmReserved;
        for (uint256 v; v < vaults.length; v++) {
            sum += escrow.reservedBy(scA, address(vaults[v]), REASON_REDEEM, address(usdc), 0);
        }
        for (uint256 i; i < reqs.length; i++) {
            if (!reqs[i].isDeposit) continue;
            sum += escrow.reservedBy(
                scA, address(vaults[reqs[i].vault]), _depositReason(uint96(reqs[i].requestId)), address(usdc), 0
            );
        }
        eq(reserved, sum, "holding.reserved != sum of keyed reservations");
    }

    //----------------------------------------------------------------------------------------------
    // Accounting and holdings
    //----------------------------------------------------------------------------------------------

    /// @dev Double entry: per pool, the debits across its accounts equal the credits.
    function property_accounting_books_balance() public {
        PoolId[3] memory pools = [poolA, poolB, poolC];
        AccountId[4] memory accounts = _accounts();
        for (uint256 p; p < pools.length; p++) {
            uint256 debits;
            uint256 credits;
            for (uint256 i; i < accounts.length; i++) {
                (uint128 totalDebit, uint128 totalCredit,,,) = accounting.accounts(pools[p], accounts[i]);
                debits += totalDebit;
                credits += totalCredit;
            }
            eq(debits, credits, "per-pool debits != credits");
        }
    }

    /// @dev Totals stay below `int128.max`, which downstream signed casts rely on.
    function property_accountTotalsFitInt128() public {
        PoolId[3] memory pools = [poolA, poolB, poolC];
        AccountId[4] memory accounts = _accounts();
        for (uint256 p; p < pools.length; p++) {
            for (uint256 i; i < accounts.length; i++) {
                (uint128 totalDebit, uint128 totalCredit,,,) = accounting.accounts(pools[p], accounts[i]);
                lt(totalDebit, uint128(type(int128).max), "totalDebit reached int128.max");
                lt(totalCredit, uint128(type(int128).max), "totalCredit reached int128.max");
            }
        }
    }

    /// @dev The asset account is shared by every holding on it, so it carries their summed value. Manual
    ///      journal entries can move it on their own, which is why the journal handler never touches it.
    function property_accounting_and_holdings_soundness() public {
        uint256 valueA = uint256(holdings.value(poolA, scA, usdcId)) + holdings.value(poolA, scA, cShareId);
        _checkAssetAccount(poolA, valueA);
        _checkAssetAccount(poolB, holdings.value(poolB, scB, usdcId));
        _checkAssetAccount(poolC, holdings.value(poolC, scC, usdcId));
    }

    function _checkAssetAccount(PoolId poolId, uint256 value) internal {
        (bool isPositive, uint128 accountValue) = accounting.accountValue(poolId, ASSET_ACCOUNT);
        t(isPositive || accountValue == 0, "asset account negative");
        eq(accountValue, value, "asset account value != sum of holding values");
    }

    /// @dev A holding with zero amount carries zero value: no phantom NAV stranded on an emptied holding.
    function property_holdingZeroAmountHasZeroValue() public {
        AssetId[3] memory assets = _poolAssets();
        for (uint256 i; i < assets.length; i++) {
            if (holdings.amount(poolA, scA, assets[i]) == 0) {
                eq(holdings.value(poolA, scA, assets[i]), 0, "zero-amount holding carries value");
            }
        }
    }

    /// @dev What one operation may change, judged on its own before and after snapshots.
    ///      A fall in a holding's value never raises the value of the accounts it books against, the loss account
    ///      excepted, which is where the fall lands. Only the hub moves prices: no investor or manager operation
    ///      changes the price per share a vault reports, the spoke's notified price or the hub's. Across any one
    ///      operation that did not flush, the signed queue moves by exactly the supply change, whichever way it
    ///      crosses zero, and the nonce never goes backwards.
    function _checkDeltas() internal override {
        if (currentOperation == OpType.PRICE) {
            uint256 before_ = uint256(_before.holdingValue[0]) + _before.holdingValue[1];
            uint256 after_ = uint256(_after.holdingValue[0]) + _after.holdingValue[1];
            if (after_ < before_) {
                for (uint256 i; i < 3; i++) {
                    if (_after.accountPositive[i] && _after.accountValue[i] > _before.accountValue[i]) {
                        t(false, "accountValue increased on a valuation decrease");
                    }
                }
            }
        } else {
            eq(
                _after.pricePerShare[sampledVault],
                _before.pricePerShare[sampledVault],
                "vault pricePerShare moved without a price update"
            );
            eq(_after.spokeSharePrice.raw(), _before.spokeSharePrice.raw(), "spoke share price moved");
            eq(_after.hubSharePrice.raw(), _before.hubSharePrice.raw(), "hub share price moved");
        }
        gte(_after.nonce, _before.nonce, "nonce decreased");
        if (_after.nonce == _before.nonce) {
            t(
                _after.queuedShares - _before.queuedShares == int256(_after.supply) - int256(_before.supply),
                "share queue moved apart from supply"
            );
        }
    }

    /// @dev `deficitCount` equals the holdings whose decreases exceed their increases, and the network
    ///      rollup equals its share classes' sum.
    function property_deficitCountMatchesHoldings() public {
        uint256 count;
        AssetId[3] memory assets = _poolAssets();
        for (uint256 i; i < assets.length; i++) {
            (uint256 increased, uint256 decreased) = holdings.holdingAmounts(poolA, scA, assets[i]);
            if (decreased > increased) count++;
        }
        eq(holdings.deficitCount(poolA, scA, CENTRIFUGE_ID), count, "deficitCount != holdings in deficit");
        eq(holdings.networkDeficitCount(poolA, CENTRIFUGE_ID), count, "networkDeficitCount != sum");
    }

    //----------------------------------------------------------------------------------------------
    // Snapshot queue
    //----------------------------------------------------------------------------------------------

    /// @dev The queued share delta is the supply the hub has not been told about yet: issuance minus
    ///      revocation since the last flush, signed, which is how flips stay correct.
    function property_shareQueueCommutativity() public {
        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(poolA, scA);
        int256 expected =
            int256(shareA.totalSupply()) - int256(uint256(shareClassManager.issuance(poolA, scA, CENTRIFUGE_ID)));
        t(_signed(delta, isPositive) == expected, "queued share delta != supply - hub issuance");
    }

    /// @dev The sign flag agrees with the delta: zero is never positive.
    function property_deltaCheck() public {
        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(poolA, scA);
        if (delta == 0) t(!isPositive, "zero share delta flagged positive");
    }

    /// @dev The nonce is one shared sequence for asset and share flushes and never goes backwards.
    function property_nonceMonotonicity() public {
        (,,, uint64 nonce) = snapshotQueue.queuedShares(poolA, scA);
        eq(nonce, ghost_shareQueueFlushes, "nonce != flushes submitted");
    }

    function property_assetQueueCounterConsistency() public {
        (,, uint32 counter,) = snapshotQueue.queuedShares(poolA, scA);
        uint256 nonEmpty;
        AssetId[3] memory assets = _poolAssets();
        for (uint256 i; i < assets.length; i++) {
            (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(poolA, scA, assets[i]);
            if (deposits != 0 || withdrawals != 0) nonEmpty++;
        }
        eq(counter, nonEmpty, "queuedAssetCounter != non-empty asset queues");
    }

    function property_assetCounterBounds() public {
        (,, uint32 counter,) = snapshotQueue.queuedShares(poolA, scA);
        lte(counter, _poolAssets().length, "queuedAssetCounter exceeds the tracked assets");
    }

    //----------------------------------------------------------------------------------------------
    // Authorization
    //----------------------------------------------------------------------------------------------

    /// @dev No balance-sheet operation by a caller who was neither ward nor manager went through.
    function property_authorizationBypass() public {
        eq(ghost_unauthorizedSuccess, 0, "a privileged spoke call succeeded without authority");
    }

    /// @dev The last successful privileged caller is still one the registry recognises, unless it was the
    ///      auxiliary manager and its role was revoked since.
    function property_authorizationLevel() public {
        if (ghost_privilegedOperationCount == 0) return;
        address last = ghost_lastAuthorizedCaller;
        if (last == AUX_MANAGER && !auxIsManager) return;
        t(spoke.wards(last) == 1 || spokeRegistry.manager(poolA, last), "privileged call by an unauthorized address");
    }

    /// @dev Role changes through the hub land on the spoke exactly, and a revoked manager is locked out.
    function property_authorizationChange() public {
        t(spokeRegistry.manager(poolA, AUX_MANAGER) == auxIsManager, "manager role diverged from the hub's grants");
        eq(ghost_callsAfterRevocation, 0, "a revoked manager kept operating");
    }

    //----------------------------------------------------------------------------------------------
    // Vault value flow
    //----------------------------------------------------------------------------------------------

    /// @dev Shares paid out by async claims never exceed what fulfillments and redeem cancellations made
    ///      claimable, per vault.
    function property_sum_of_shares_received() public {
        for (uint256 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            lte(ghost_sharesClaimed[vault], ghost_sharesOwed[vault], "claimed shares > fulfilled shares");
        }
    }

    /// @dev Assets paid out by async claims never exceed what redeem fulfillments and deposit
    ///      cancellations made claimable, per vault.
    function property_sum_of_assets_received() public {
        for (uint256 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            lte(ghost_assetsClaimed[vault], ghost_assetsOwed[vault], "claimed assets > fulfilled payout");
        }
    }

    /// @dev Requested amounts bound what the manager fulfilled and cancelled, on each side.
    function property_cancelled_and_processed_deposits_soundness() public {
        for (uint256 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            gte(
                ghost_requested[vault][true],
                ghost_fulfilledGross[vault][true] + ghost_cancelledGross[vault][true],
                "deposits fulfilled + cancelled > requested"
            );
        }
    }

    function property_cancelled_and_processed_redemptions_soundness() public {
        for (uint256 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            gte(
                ghost_requested[vault][false],
                ghost_fulfilledGross[vault][false] + ghost_cancelledGross[vault][false],
                "redemptions fulfilled + cancelled > requested"
            );
        }
    }

    /// @dev Bucket-level conservation: what was requested and not yet settled or cancelled is pending.
    function property_actor_pending_and_queued_deposits() public {
        _checkPendingConservation(true);
    }

    function property_actor_pending_and_queued_redemptions() public {
        _checkPendingConservation(false);
    }

    function _checkPendingConservation(bool isDeposit) internal {
        for (uint256 v; v < vaults.length; v++) {
            address vault = address(vaults[v]);
            uint256 pending;
            for (uint256 i; i < reqs.length; i++) {
                if (reqs[i].vault != v || reqs[i].isDeposit != isDeposit) continue;
                pending += BucketReference.outstanding(vaults[v].bucket(uint96(reqs[i].requestId)));
            }
            eq(
                pending + ghost_fulfilledGross[vault][isDeposit] + ghost_cancelledGross[vault][isDeposit],
                ghost_requested[vault][isDeposit],
                "requested != pending + fulfilled + cancelled"
            );
        }
    }

    /// @dev The OrderBook's outstanding order is what the vault flushed and the hub has not settled.
    function property_orderBookMatchesBuckets() public {
        for (uint256 i; i < reqs.length; i++) {
            Req memory r = reqs[i];
            Bucket memory b = vaults[r.vault].bucket(uint96(r.requestId));
            RequestId rid = RequestId.wrap(r.requestId);
            uint128 outstanding = r.isDeposit
                ? orderBook.depositOrders(poolA, scA, usdcId, rid)
                : orderBook.redeemOrders(poolA, scA, usdcId, rid);
            t(BucketReference.outstanding(b) >= b.queued, "a bucket queued more than it has outstanding");
            eq(outstanding, _floorSub(BucketReference.outstanding(b), b.queued), "hub order != spoke bucket");
        }
    }

    /// @dev A deposit request's assets stay reserved under its own key until settled or cancelled, by
    ///      exactly the bucket's pending amount.
    function property_pendingDepositsStayReservedPerRequest() public {
        IEscrow escrow = _escrow(poolA);
        for (uint256 i; i < reqs.length; i++) {
            Req memory r = reqs[i];
            if (!r.isDeposit) continue;
            uint96 localId = uint96(r.requestId);
            uint128 reserved =
                escrow.reservedBy(scA, address(vaults[r.vault]), _depositReason(localId), address(usdc), 0);
            eq(
                reserved,
                BucketReference.outstanding(vaults[r.vault].bucket(localId)),
                "deposit reservation != bucket pending"
            );
        }
    }

    /// @dev Escrow backing of entitlements: every claimable payout is reserved under its vault's redeem
    ///      reason, and claimable plus pending-redeem shares never exceed the escrow's share balance.
    ///      `investments` counts unfolded per-period slices, so nothing is folded to read them.
    function property_sum_of_possible_account_balances_leq_escrow() public {
        IEscrow escrow = _escrow(poolA);
        uint256 owedShares;
        for (uint256 v; v < vaults.length; v++) {
            uint256 owedAssets;
            for (uint256 a; a < actors.length; a++) {
                owedShares += vaults[v].claimableMint(actors[a]);
                owedAssets += vaults[v].claimableWithdraw(actors[a]);
            }
            uint128 reserved = escrow.reservedBy(scA, address(vaults[v]), REASON_REDEEM, address(usdc), 0);
            lte(owedAssets, reserved, "claimable payouts exceed the redeem reservation");
        }
        for (uint256 i; i < reqs.length; i++) {
            if (reqs[i].isDeposit) continue;
            owedShares += BucketReference.outstanding(vaults[reqs[i].vault].bucket(uint96(reqs[i].requestId)));
        }
        lte(owedShares + ghost_bsmEscrowShares, shareA.balanceOf(address(escrow)), "share claims exceed the escrow");
    }

    /// @dev Each controller's ERC-7540 aggregate equals the sum of its per-request pending amounts, on both
    ///      sides: the vault's pending totals and its horizon accounting agree with every bucket.
    function property_pendingTotalsMatchTheRequests() public {
        for (uint256 v; v < vaults.length; v++) {
            for (uint256 a; a < actors.length; a++) {
                uint256 deposits;
                uint256 redeems;
                for (uint256 i; i < reqs.length; i++) {
                    if (reqs[i].vault != v) continue;
                    if (reqs[i].isDeposit) deposits += vaults[v].pendingDepositRequest(reqs[i].requestId, actors[a]);
                    else redeems += vaults[v].pendingRedeemRequest(reqs[i].requestId, actors[a]);
                }
                eq(deposits, vaults[v].pendingDepositRequest(0, actors[a]), "pending deposits disagree with the total");
                eq(redeems, vaults[v].pendingRedeemRequest(0, actors[a]), "pending redemptions disagree with the total");
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // NAV pool
    //----------------------------------------------------------------------------------------------

    /// @dev The pool's NAV is the signed sum of its networks'. Each network's NAV is what its assets and liability
    ///      come to by an independent sum, a network that carries more debt than assets reports a negative NAV, the
    ///      price manager holds what each network reported at its last snapshot, and the global NAV and issuance are
    ///      the sums of those. A network that floored its NAV at zero, or a sum taken through a clamp, fails here.
    function property_navPoolSumsTheNetworks() public {
        uint16[2] memory nets = [NAV_NET_A, NAV_NET_B];
        int256 reportedSum;
        uint256 issuanceSum;
        bool anySynced;
        for (uint256 n; n < 2; n++) {
            t(
                int256(navManager.netAssetValue(poolN, nets[n])) == _ghostNav(nets[n]),
                "a network's NAV is not what its holdings come to"
            );
            (int128 reportedNav, uint128 reportedIssuance,,,,) = priceManager.networkMetrics(poolN, nets[n]);
            reportedSum += reportedNav;
            issuanceSum += reportedIssuance;
            if (!ghostNavSynced[nets[n]]) continue;
            anySynced = true;
            t(int256(reportedNav) == ghostNavSyncedNav[nets[n]], "the price manager lost what a network reported");
            eq(reportedIssuance, ghostNavSyncedShares[nets[n]], "the price manager's issuance is not the network's");
        }
        (int128 globalNav, uint128 globalIssuance) = priceManager.metrics(poolN);
        t(int256(globalNav) == reportedSum, "the pool's NAV is not the signed sum of its networks'");
        eq(globalIssuance, issuanceSum, "the pool's issuance is not the sum of its networks'");

        if (!anySynced) return;
        (D18 price,) = shareClassManager.pricePoolPerShare(poolN, scN);
        uint256 expected =
            globalIssuance == 0 ? 1e18 : globalNav <= 0 ? 0 : uint256(uint128(globalNav)) * 1e18 / globalIssuance;
        eq(price.raw(), expected, "the share price is not the pool's NAV over its issuance");
    }

    //----------------------------------------------------------------------------------------------
    // Isolation
    //----------------------------------------------------------------------------------------------

    /// @dev Nothing the fuzzer does to pool A or C moves pool B. B has a manager of its own, so neither FM nor the
    ///      BSM holds a role there: the footprint (queues, accounts, prices, roles, links, escrow, holding, supply,
    ///      the singletons' per-vault state, orders) changes only on a boundary crossing.
    function property_poolBIsUntouched() public {
        t(_footprintB() == footprintB, "pool B state moved");
    }

    /// @dev The same for the adversary's pool D. Its manager acts through the isolation handlers only, and each
    ///      of those must leave D as it was too, so D's footprint is fixed from setup.
    function property_poolDIsUntouched() public {
        t(_footprintD() == footprintD, "pool D state moved");
    }

    /// @dev Pool D's books stay closed whatever the adversary does elsewhere: its supply sits with its investor and
    ///      its escrow, and the escrow's USDC balance is its holding total (so a leak into or out of D shows even
    ///      before the footprint is compared).
    function property_poolDIsConsistent() public {
        IEscrow escrowD = _escrow(poolD);
        eq(
            shareD.totalSupply(),
            shareD.balanceOf(INVESTOR_D) + shareD.balanceOf(address(escrowD)),
            "pool D supply outside its holders"
        );
        (uint128 total,) = escrowD.holding(scD, address(usdc), 0);
        eq(usdc.balanceOf(address(escrowD)), total, "pool D escrow USDC balance != holding total");
        eq(usdc.balanceOf(MALLORY), 0, "the adversary holds USDC");
    }

    //----------------------------------------------------------------------------------------------
    // Prices
    //----------------------------------------------------------------------------------------------

    /// @dev The oracle's verdict is its specification: valid exactly when the pool has not paused it and
    ///      both prices were notified, neither is older than `maxAge` and they were notified at most
    ///      `maxSkew` apart.
    function property_oracleVerdict() public {
        uint64 assetAt = spokeRegistry.pricePoolPerAssetComputedAt(poolA, scA, usdcId);
        uint64 shareAt = spokeRegistry.pricePoolPerShareComputedAt(poolA, scA);
        uint256 maxAge = spokeOracle.maxAge();
        bool fresh = assetAt != 0 && shareAt != 0 && block.timestamp <= uint256(assetAt) + maxAge
            && block.timestamp <= uint256(shareAt) + maxAge;
        uint256 skew = assetAt > shareAt ? assetAt - shareAt : shareAt - assetAt;
        bool expected = !spokeOracle.isPaused(poolA) && fresh && skew <= spokeOracle.maxSkew();
        t(_oracleVerdict() == expected, "oracle verdict disagrees with pause, age and skew");
    }

    /// @dev On a price the oracle refuses, the instant lane is closed: the instant vaults' previews revert
    ///      with `InvalidPrice` (the async-only vaults' always revert, having no lane to quote), and
    ///      for a controller with nothing pending or claimable on a side (whose `max*` would otherwise
    ///      read the lane's capacity) both `max*` views of that side read zero.
    function property_invalidPriceClosesInstantLane() public {
        if (_oracleValid()) return;
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            if (address(vault.instantPolicy()) != address(0)) _checkPreviewsRevert(vault);
            for (uint256 a; a < actors.length; a++) {
                if (vault.claimableMint(actors[a]) == 0 && vault.pendingDepositRequest(0, actors[a]) == 0) {
                    eq(
                        vault.maxDeposit(actors[a]) + vault.maxMint(actors[a]),
                        0,
                        "instant deposit open on an invalid price"
                    );
                }
                if (vault.claimableWithdraw(actors[a]) == 0 && vault.pendingRedeemRequest(0, actors[a]) == 0) {
                    eq(
                        vault.maxWithdraw(actors[a]) + vault.maxRedeem(actors[a]),
                        0,
                        "instant redeem open on an invalid price"
                    );
                }
            }
        }
    }

    function _checkPreviewsRevert(IAsyncVault vault) internal {
        bytes4[4] memory previews = [
            vault.previewDeposit.selector,
            vault.previewMint.selector,
            vault.previewWithdraw.selector,
            vault.previewRedeem.selector
        ];
        for (uint256 i; i < previews.length; i++) {
            (bool success, bytes memory err) = address(vault).staticcall(abi.encodeWithSelector(previews[i], ONE_ASSET));
            t(!success && bytes4(err) == IVaultErrors.InvalidPrice.selector, "a preview answered on an invalid price");
        }
    }

    /// @dev A read that reverts is a failure, which a `view` property could not report to the fuzzers: an assertion
    ///      mode fuzzer only counts a failed assertion, not a revert.
    function _answers(address target, bytes memory data) internal {
        (bool ok,) = target.staticcall(data);
        t(ok, "a read an integrator relies on reverted");
    }

    /// @dev The whole share supply valued at the oracle's prices, in asset units and 256 bits: what `totalAssets` has to
    ///      fit in a `uint128`, worked out without the vault's own conversion so that the check below does not read
    ///      the answer it judges.
    function _supplyValue() internal view returns (uint256) {
        (D18 ppa, D18 pps,) = spokeOracle.prices(poolA, scA, usdcId);
        if (ppa.isZero()) return 0;
        uint256 inPool = MathLib.mulDiv(shareA.totalSupply(), pps.raw(), ppa.raw(), MathLib.Rounding.Down);
        return MathLib.mulDiv(inPool, ONE_ASSET, ONE_SHARE, MathLib.Rounding.Down);
    }

    /// @dev Well inside `uint128`, so a conversion of the supply must answer. One percent of margin, since the vault's
    ///      own rounding differs from the valuation above.
    function _supplyIsRepresentable(IAsyncVault) internal view returns (bool) {
        return _supplyValue() <= uint256(type(uint128).max) / 100 * 99;
    }

    /// @dev `totalAssets` is the supply's value, so it answers while that fits a `uint128` and reverts once it clearly
    ///      does not (src/vaults/SPECIFICATION.md, the row on `totalAssets` and `uint128`); between the two, rounding
    ///      decides and nothing is asserted.
    function _totalAssetsFollowsTheRange(IAsyncVault vault) internal {
        if (_supplyIsRepresentable(vault)) {
            _answers(address(vault), abi.encodeCall(vault.totalAssets, ()));
        } else if (_supplyValue() > uint256(type(uint128).max) / 100 * 101) {
            (bool answered,) = address(vault).staticcall(abi.encodeCall(vault.totalAssets, ()));
            t(!answered, "totalAssets answered a value that has no uint128");
        }
    }

    /// @dev Reads an integrator relies on never revert, in any state the flows reach.
    function property_viewsNeverRevert() public {
        _answers(address(accounting), abi.encodeCall(accounting.accountValue, (poolA, ASSET_ACCOUNT)));
        _answers(address(accounting), abi.encodeCall(accounting.accountValue, (poolA, EQUITY_ACCOUNT)));
        _answers(address(accounting), abi.encodeCall(accounting.accountValue, (poolA, GAIN_ACCOUNT)));
        _answers(address(accounting), abi.encodeCall(accounting.accountValue, (poolA, LOSS_ACCOUNT)));
        for (uint256 v; v < vaults.length; v++) {
            IAsyncVault vault = vaults[v];
            _totalAssetsFollowsTheRange(vault);
            _answers(address(vault), abi.encodeCall(vault.convertToShares, (ONE_ASSET)));
            _answers(address(vault), abi.encodeCall(vault.convertToAssets, (ONE_SHARE)));
            for (uint256 a; a < actors.length; a++) {
                _answers(address(vault), abi.encodeCall(vault.maxDeposit, (actors[a])));
                _answers(address(vault), abi.encodeCall(vault.maxMint, (actors[a])));
                _answers(address(vault), abi.encodeCall(vault.maxWithdraw, (actors[a])));
                _answers(address(vault), abi.encodeCall(vault.maxRedeem, (actors[a])));
                _answers(address(vault), abi.encodeCall(vault.pendingDepositRequest, (0, actors[a])));
                _answers(address(vault), abi.encodeCall(vault.pendingRedeemRequest, (0, actors[a])));
                _answers(address(vault), abi.encodeCall(vault.claimableDepositRequest, (0, actors[a])));
                _answers(address(vault), abi.encodeCall(vault.claimableRedeemRequest, (0, actors[a])));
            }
        }
        _answers(address(vaultRoute), abi.encodeCall(vaultRoute.available, (address(vaults[2]))));
        _answers(address(basinRoute), abi.encodeCall(basinRoute.available, (address(vaults[3]))));
        _answers(address(shareA), abi.encodeCall(IERC20.totalSupply, ()));
    }
}
