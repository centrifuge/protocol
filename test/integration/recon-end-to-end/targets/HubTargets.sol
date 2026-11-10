// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {RequestId} from "../../../../src/core/types/RequestId.sol";
import {PricingLib} from "../../../../src/core/libraries/PricingLib.sol";
import {JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";

import {UpdateRestrictionMessageLib} from "../../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {Bucket, IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";
import {FeeManagerAction} from "../../../../src/vaults/hub/interfaces/IFeeRequestManager.sol";
import {IReserveInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";
import {IVaultLiquidityRoute} from "../../../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

/// @notice Pool manager actions: settling orders through the OrderBook, prices and valuation, the
///         journal, restrictions, manager roles, request caps and time.
abstract contract HubTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    /// @dev The largest fee the FeeRequestManager and the instant policy accept: below `MathLib.BPS`.
    uint256 internal constant MAX_FEE_BPS = 9_999;

    //----------------------------------------------------------------------------------------------
    // Settlement
    //----------------------------------------------------------------------------------------------

    /// @dev Fulfils part or all of an outstanding order through the FeeRequestManager, the path
    ///      production uses. What the fill makes claimable is read off the bucket it settled.
    function hub_fulfill(uint256 reqSeed, uint256 amount, bool full) public updateGhosts(OpType.MANAGER) {
        (Req memory r, uint128 outstanding) = _pickOrder(reqSeed, true);
        if (outstanding == 0) return;
        _fulfill(r, full ? outstanding : uint128(between(amount, _dust(r.isDeposit), outstanding)));
    }

    function _fulfill(Req memory r, uint128 fill) internal returns (bool success) {
        _feeNoInstantInCall = true;
        Bucket memory settledBefore = vaults[r.vault].bucket(uint96(r.requestId));
        uint256[2] memory claimableBefore;
        (claimableBefore[0], claimableBefore[1]) = _claimable(r.vault);
        uint256[6] memory actorsBefore = _actorClaimable(r.vault);
        bytes memory data = abi.encodeCall(
            feeRequestManager.fulfill, (poolA, scA, usdcId, RequestId.wrap(r.requestId), r.isDeposit, fill, 0, REFUND)
        );
        (success,) = _callAs(FM, address(feeRequestManager), data);
        if (!success) {
            _reverted("hub_fulfill");
            return false;
        }
        _recordFill(r, fill, settledBefore, claimableBefore, actorsBefore);
        _ok("hub_fulfill");
    }

    function _recordFill(
        Req memory r,
        uint128 fill,
        Bucket memory settledBefore,
        uint256[2] memory claimableBefore,
        uint256[6] memory actorsBefore
    ) internal {
        _noteActorsOwed(r.vault, actorsBefore, true);
        (uint256 sharesAfter, uint256 assetsAfter) = _claimable(r.vault);
        address vault = address(vaults[r.vault]);
        ghost_fulfilledGross[vault][r.isDeposit] += fill;
        ghost_settlements++;
        _noteStanding(r);
        uint256 sharesCredited =
            _nonNegativeDelta(sharesAfter, claimableBefore[0], "a fill lowered the claimable shares");
        uint256 assetsCredited =
            _nonNegativeDelta(assetsAfter, claimableBefore[1], "a fill lowered the claimable assets");
        ghost_sharesOwed[vault] += sharesCredited;
        ghost_assetsOwed[vault] += assetsCredited;
        _checkFillPrice(
            r.isDeposit,
            fill,
            vaults[r.vault].bucket(uint96(r.requestId)),
            settledBefore,
            r.isDeposit ? sharesCredited : assetsCredited
        );
    }

    function _noteStanding(Req memory r) internal {
        Bucket memory b = vaults[r.vault].bucket(uint96(r.requestId));
        if (b.total != 0 && b.settlements == 1) ghost_standingBuckets++;
    }

    /// @dev A settlement records exactly what its price and fee allow, read off the bucket it settled rather than
    ///      the claimable views, which a fill can also grow by surfacing older slices: a deposit fill less the fee
    ///      buys shares at the hub's prices, a redemption fill less the fee pays assets at them. Two-sided: a fill that
    ///      records less than its price allows under-credits the investors just as one that records more over-credits
    ///      them. A sole owner's bucket is retired by the eager fold inside the fill, so it reads as empty; the
    ///      claimable views carry its credit then, and nothing else moves in a fill.
    function _checkFillPrice(bool isDeposit, uint128 fill, Bucket memory after_, Bucket memory before, uint256 credited)
        internal
    {
        // A zero price converts to nothing, so a fill at one is bounded by nothing the conversion can express
        (D18 pps,) = shareClassManager.pricePoolPerShare(poolA, scA);
        if (hub.pricePoolPerAsset(poolA, scA, usdcId).isZero() || pps.isZero()) return;
        uint128 bound = _fillOutput(isDeposit, fill);
        bool retired = after_.total == 0 && before.total != 0;
        uint256 assets;
        uint256 shares;
        if (!retired) {
            assets =
                _nonNegativeDelta(after_.fulfilledAssets, before.fulfilledAssets, "a fill lowered the bucket's assets");
            shares =
                _nonNegativeDelta(after_.fulfilledShares, before.fulfilledShares, "a fill lowered the bucket's shares");
        } else {
            (assets, shares) = isDeposit ? (uint256(fill), credited) : (credited, uint256(fill));
        }
        if (isDeposit) {
            eq(shares, bound, "a deposit fill did not record the shares its price allows");
            eq(assets, fill, "a deposit fill did not record the assets it filled");
        } else {
            eq(assets, bound, "a redemption fill did not record the assets its price allows");
            eq(shares, fill, "a redemption fill did not record the shares it filled");
        }
    }

    /// @dev What a fill converts to at the hub's prices and the fee: shares for a deposit, assets for a redemption.
    function _fillOutput(bool isDeposit, uint128 fill) internal view returns (uint128) {
        uint128 net =
            fill - uint128(MathLib.mulDiv(fill, feeRequestManager.feeBps(poolA, usdcId), 1e4, MathLib.Rounding.Up));
        D18 ppa = hub.pricePoolPerAsset(poolA, scA, usdcId);
        (D18 pps,) = shareClassManager.pricePoolPerShare(poolA, scA);
        return isDeposit
            ? PricingLib.assetToShareAmount(address(shareA), address(usdc), 0, net, ppa, pps, MathLib.Rounding.Down)
            : PricingLib.shareToAssetAmount(address(shareA), net, address(usdc), 0, pps, ppa, MathLib.Rounding.Down);
    }

    /// @dev Cancelled deposits come back as assets on the redeem side, cancelled redemptions as shares
    ///      on the deposit side.
    function hub_cancel(uint256 reqSeed, uint256 amount, bool full) public updateGhosts(OpType.MANAGER) {
        (Req memory r, uint128 outstanding) = _pickOrder(reqSeed, false);
        if (outstanding == 0) return;
        _cancel(r, full ? outstanding : uint128(between(amount, 1, outstanding)));
    }

    function _cancel(Req memory r, uint128 gross) internal returns (bool success) {
        _feeNoInstantInCall = true;
        Bucket memory settledBefore = vaults[r.vault].bucket(uint96(r.requestId));
        uint256[2] memory claimableBefore;
        (claimableBefore[0], claimableBefore[1]) = _claimable(r.vault);
        uint256[6] memory actorsBefore = _actorClaimable(r.vault);
        bytes memory data = abi.encodeCall(
            feeRequestManager.cancel, (poolA, scA, usdcId, RequestId.wrap(r.requestId), r.isDeposit, gross, 0, REFUND)
        );
        (success,) = _callAs(FM, address(feeRequestManager), data);
        if (!success) {
            _reverted("hub_cancel");
            return false;
        }
        _recordCancel(r, gross, settledBefore, claimableBefore, actorsBefore);
        _ok("hub_cancel");
    }

    function _recordCancel(
        Req memory r,
        uint128 gross,
        Bucket memory settledBefore,
        uint256[2] memory claimableBefore,
        uint256[6] memory actorsBefore
    ) internal {
        _noteActorsOwed(r.vault, actorsBefore, true);
        (uint256 sharesAfter, uint256 assetsAfter) = _claimable(r.vault);
        address vault = address(vaults[r.vault]);
        ghost_cancelledGross[vault][r.isDeposit] += gross;
        ghost_settlements++;
        _noteStanding(r);
        ghost_sharesOwed[
            vault
        ] += _nonNegativeDelta(sharesAfter, claimableBefore[0], "a cancel lowered the claimable shares");
        ghost_assetsOwed[
            vault
        ] += _nonNegativeDelta(assetsAfter, claimableBefore[1], "a cancel lowered the claimable assets");
        // No cancellation fee: the bucket retires exactly the gross, all of it refundable (a retired bucket reads empty)
        Bucket memory settledAfter = vaults[r.vault].bucket(uint96(r.requestId));
        if (settledAfter.total != 0) {
            uint256 net =
                _nonNegativeDelta(settledAfter.cancelledNet, settledBefore.cancelledNet, "a cancel lowered net");
            eq(net, gross, "a cancel recorded other than the gross as refundable");
        }
    }

    /// @dev The FeeRequestManager's per-asset fee: fills then credit less than they consume. Usually up to 5%, one
    ///      call in four anywhere up to the 99.99% the manager accepts, where a fee takes almost every fill.
    function hub_setFee(uint16 bps, bool wide) public updateGhosts(OpType.TERMS) {
        bps = uint16(wide ? between(bps, 501, MAX_FEE_BPS) : between(bps, 0, 500));
        _managerCall(poolA, address(feeRequestManager), abi.encode(uint8(FeeManagerAction.SetFee), usdcId.raw(), bps));
        _ok("hub_setFee");
    }

    //----------------------------------------------------------------------------------------------
    // Instant lanes and routes
    //----------------------------------------------------------------------------------------------

    /// @dev Re-terms an instant vault's lane: its fees, whether redemptions are open, which lanes are gated and the
    ///      reserve its deposits fill. The fee destination stays what setup chose for that vault. Gates are mostly
    ///      off and caps mostly generous, so the lanes keep trading between the changes.
    function policy_configure(uint256 vaultSeed, uint16 feeBps, uint256 flags, uint256 capSeed, bool wide)
        public
        updateGhosts(OpType.TERMS)
    {
        IAsyncVault vault = vaults[2 + vaultSeed % 2];
        (address feeRecipient,,,,,,) = reserveInstantPolicy.config(address(vault));
        uint128 cap = capSeed % 6 == 0 ? 0 : uint128(between(capSeed, ACTOR_FUNDS / 10, ACTOR_FUNDS));
        // Wide: fees up to the policy's bound and a reserve far above anything funded, as large as the accounts leave
        // room for, since a deposit that fills it is booked in them
        if (wide) cap = uint128(_larger(_hugeAssets() / 4, ACTOR_FUNDS));
        (uint256 maxFee, uint256 maxRedeemFee) = wide ? (MAX_FEE_BPS, MAX_FEE_BPS) : (500, 500);
        bytes memory terms = abi.encode(
            feeRecipient,
            uint16(between(feeBps, 0, maxFee)),
            uint16(between(feeBps / 2, 0, maxRedeemFee)),
            flags % 8 != 0,
            flags % 5 == 0,
            flags % 7 == 0,
            cap
        );
        _managerCall(
            poolA,
            address(reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(vault), terms)
        );
        _ok("policy_configure");
    }

    /// @dev Allows or bars one account on a gated lane. Only the caller is gated, never the receiver.
    function policy_allow(uint256 vaultSeed, uint256 actorSeed, bool isDeposit, bool allowed)
        public
        updateGhosts(OpType.TERMS)
    {
        IAsyncVault vault = vaults[2 + vaultSeed % 2];
        _managerCall(
            poolA,
            address(reserveInstantPolicy),
            abi.encode(
                isDeposit ? IReserveInstantPolicy.ConfigKind.Depositor : IReserveInstantPolicy.ConfigKind.Redeemer,
                address(vault),
                abi.encode(_actor(actorSeed), allowed)
            )
        );
        _ok("policy_allow");
    }

    /// @dev The underlying pool grants or withdraws the top vault's right to draw on it.
    function route_consent(bool allowed) public updateGhosts(OpType.MANAGER) {
        _managerCall(
            poolC,
            address(vaultRoute),
            abi.encode(
                IVaultLiquidityRoute.ConfigKind.Consent, address(vaultC), abi.encode(address(vaults[2]), allowed)
            )
        );
        _ok("route_consent");
    }

    /// @dev The top pool routes to the underlying, or to nothing.
    function route_setRoutes(bool include) public updateGhosts(OpType.MANAGER) {
        address[] memory underlying = new address[](include ? 1 : 0);
        if (include) underlying[0] = address(vaultC);
        _managerCall(
            poolA,
            address(vaultRoute),
            abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, address(vaults[2]), abi.encode(underlying))
        );
        _ok("route_setRoutes");
    }

    //----------------------------------------------------------------------------------------------
    // Prices and valuation
    //----------------------------------------------------------------------------------------------

    /// @dev Reprices pool A's share class on the hub and notifies both prices to the spoke.
    function hub_updateSharePrice(uint256 price, uint8 mode) public updateGhosts(OpType.PRICE) {
        _pushPrices(poolA, scA, _price(price, mode, 5e17, 4e18, 1e27));
        _ok("hub_updateSharePrice");
    }

    /// @dev Feeds a new USDC price and revalues the holding. Right after `update()` the holding is worth
    ///      exactly its valuation's quote for its amount.
    function hub_updateHoldingValue(uint256 price, uint8 mode) public updateGhosts(OpType.PRICE) {
        D18 newPrice = _holdingPrice(price, mode);
        _authorize(poolA, abi.encodeCall(hub.updateHoldingValue, (poolA, scA, usdcId)));
        vm.prank(FEEDER);
        oracleValuation.setPrice(poolA, scA, usdcId, newPrice);
        _fm();
        hub.updateHoldingValue(poolA, scA, usdcId);
        uint128 amount = holdings.amount(poolA, scA, usdcId);
        eq(
            holdings.value(poolA, scA, usdcId),
            oracleValuation.getQuote(poolA, scA, usdcId, amount),
            "holding value != getQuote(amount) after update"
        );
        _fm();
        hub.notifyAssetPrice(poolA, scA, usdcId, REFUND);
        _ok("hub_updateHoldingValue");
    }

    /// @dev Time passes, closing per-period windows. Prices are re-notified so the oracle's freshness
    ///      bound does not close the instant lanes for the rest of the run.
    function hub_warp(uint256 secs) public updateGhosts(OpType.PRICE) {
        vm.warp(block.timestamp + between(secs, 1 minutes, 3 hours));
        (D18 pps,) = shareClassManager.pricePoolPerShare(poolA, scA);
        _pushPrices(poolA, scA, pps);
        _pushPrices(poolC, scC, _poolCPrice());
        _ok("hub_warp");
    }

    //----------------------------------------------------------------------------------------------
    // Journal
    //----------------------------------------------------------------------------------------------

    /// @dev Manual entries between the non-asset accounts. An unbalanced entry must never land.
    ///      One entry in eight is as large as the accounts have room for: up to half of `int128.max` in total, which the
    ///      protocol's own flows must never be pushed past, so `property_accountTotalsFitInt128` stays meaningful.
    function hub_updateJournal(uint8 debitSeed, uint8 creditSeed, uint128 debit, uint128 credit, uint8 mode)
        public
        updateGhosts(OpType.MANAGER)
    {
        AccountId[3] memory accounts = [EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT];
        uint256 room = _journalRoom(accounts[debitSeed % 3], accounts[creditSeed % 3]);
        uint256 cap = mode % 8 == 0 ? room : MathLib.min(room, 1_000_000 * ONE_SHARE);
        if (cap == 0) return;
        JournalEntry[] memory debits = new JournalEntry[](1);
        JournalEntry[] memory credits = new JournalEntry[](1);
        debits[0] = JournalEntry({value: uint128(between(debit, 1, cap)), accountId: accounts[debitSeed % 3]});
        credits[0] = JournalEntry({value: uint128(between(credit, 1, cap)), accountId: accounts[creditSeed % 3]});
        if (debitSeed % 2 == 0) credits[0].value = debits[0].value;

        (bool success,) = _callAs(FM, address(hub), abi.encodeCall(hub.updateJournal, (poolA, debits, credits)));
        if (success) {
            eq(debits[0].value, credits[0].value, "an unbalanced journal entry landed");
            _ok("hub_updateJournal");
        } else {
            _reverted("hub_updateJournal");
        }
    }

    //----------------------------------------------------------------------------------------------
    // Restrictions and roles
    //----------------------------------------------------------------------------------------------

    /// @dev At most one investor is frozen at a time, so the others keep the flows moving.
    function hub_freeze(uint256 actorSeed) public updateGhosts(OpType.MANAGER) {
        address actor = _actor(actorSeed);
        for (uint256 i; i < actors.length; i++) {
            if (frozen[actors[i]]) return;
        }
        _updateRestriction(
            poolA, scA, UpdateRestrictionMessageLib.UpdateRestrictionFreeze({user: actor.toBytes32()}).serialize()
        );
        frozen[actor] = true;
        _ok("hub_freeze");
    }

    function hub_unfreeze() public updateGhosts(OpType.MANAGER) {
        for (uint256 i; i < actors.length; i++) {
            if (!frozen[actors[i]]) continue;
            _updateRestriction(
                poolA,
                scA,
                UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze({user: actors[i].toBytes32()}).serialize()
            );
            frozen[actors[i]] = false;
            _ok("hub_unfreeze");
        }
    }

    /// @dev Sets when the outsider's membership lapses: at most a few hours out, or never. Membership can
    ///      only be shortened to a time not yet passed, so a lapse is reached by warping past it.
    function hub_updateMember(uint256 duration, bool forever) public updateGhosts(OpType.MANAGER) {
        uint64 validUntil = forever ? type(uint64).max : uint64(block.timestamp + between(duration, 0, 6 hours));
        _updateRestriction(
            poolA,
            scA,
            UpdateRestrictionMessageLib.UpdateRestrictionMember({
                user: OUTSIDER.toBytes32(), validUntil: validUntil
            }).serialize()
        );
        outsiderValidUntil = validUntil;
        _ok("hub_updateMember");
    }

    /// @dev Grants or revokes the auxiliary balance-sheet manager through the hub.
    function hub_updateSpokeManager(bool canManage) public updateGhosts(OpType.MANAGER) {
        _updateManager(poolA, AUX_MANAGER, canManage);
        if (auxIsManager != canManage) ghost_authorizationChanges++;
        auxIsManager = canManage;
        _ok("hub_updateSpokeManager");
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev Claimable shares and assets across the actors, unfolded slices included (`investments` reads
    ///      them), so a settlement's credit is measured whichever policy folds it, and without folding:
    ///      a fold here would leave the fold handlers nothing to do.
    /// @dev The first order from `reqSeed` with something outstanding. A fulfillment skips dust: an order
    ///      that converts to nothing is refused by the OrderBook and can only be cancelled.
    function _pickOrder(uint256 reqSeed, bool skipDust) internal view returns (Req memory r, uint128 outstanding) {
        for (uint256 i; i < reqs.length; i++) {
            r = reqs[(reqSeed + i) % reqs.length];
            outstanding = _outstanding(r);
            if (outstanding != 0 && (!skipDust || outstanding >= _dust(r.isDeposit))) return (r, outstanding);
        }
        return (r, 0);
    }

    function _outstanding(Req memory r) internal view returns (uint128) {
        RequestId rid = RequestId.wrap(r.requestId);
        return r.isDeposit
            ? orderBook.depositOrders(poolA, scA, usdcId, rid)
            : orderBook.redeemOrders(poolA, scA, usdcId, rid);
    }

    /// @dev Whether a fill of `fill` assets buys any shares at the hub's prices and the fee: the OrderBook refuses one
    ///      that buys none. A larger fill buys at least as much, so the smallest a flow makes decides for them all.
    function _fillBuysShares(uint128 fill) internal view returns (bool) {
        D18 ppa = hub.pricePoolPerAsset(poolA, scA, usdcId);
        (D18 pps,) = shareClassManager.pricePoolPerShare(poolA, scA);
        if (ppa.isZero() || pps.isZero()) return false;
        uint128 net =
            fill - uint128(MathLib.mulDiv(fill, feeRequestManager.feeBps(poolA, usdcId), 1e4, MathLib.Rounding.Up));
        return
            PricingLib.assetToShareAmount(address(shareA), address(usdc), 0, net, ppa, pps, MathLib.Rounding.Down) > 0;
    }

    /// @dev A price in the band the pool usually trades in, one call in eight anywhere from a billionth of par up to
    ///      `wideHi`, and one in 64 zero, which the oracle passes on and the vault refuses. The USDC price tops out at a
    ///      thousand times par, so that the value of the assets, which every flow books in the accounts, cannot reach
    ///      `int128.max` through ordinary traffic.
    function _price(uint256 seed, uint8 mode, uint256 lo, uint256 hi, uint256 wideHi) internal returns (D18) {
        if (mode % 64 == 0) return d18(0);
        if (mode % 8 == 1) return d18(uint128(between(seed, 1e9, wideHi)));
        return d18(uint128(between(seed, lo, hi)));
    }

    /// @dev The USDC price the feeder reports. Held to what keeps the holding's value, and so the accounts it is
    ///      booked in, under a quarter of their room: the revaluation books the whole difference.
    function _holdingPrice(uint256 seed, uint8 mode) internal returns (D18 price) {
        price = _price(seed, mode, 5e17, 2e18, 1e21);
        // Every asset that exists can end up in the holding, so the price is bounded against the whole supply
        uint256 maxPrice = _accountRoom() / 4 * 1e18 * ONE_ASSET / (usdc.totalSupply() * ONE_SHARE + 1);
        if (price.raw() > maxPrice) price = d18(uint128(MathLib.min(maxPrice, type(uint128).max)));
    }

    /// @dev Pool C's current share price, so a refresh keeps what the fuzzer set rather than resetting it to par.
    function _poolCPrice() internal view returns (D18 price) {
        (price,) = shareClassManager.pricePoolPerShare(poolC, scC);
    }

    /// @dev Room for a journal entry between two accounts: half of `int128.max`, less what either side holds.
    function _journalRoom(AccountId debitAccount, AccountId creditAccount) internal view returns (uint256) {
        (uint128 totalDebit,,,,) = accounting.accounts(poolA, debitAccount);
        (, uint128 totalCredit,,,) = accounting.accounts(poolA, creditAccount);
        uint256 budget = uint256(uint128(type(int128).max)) / 2;
        uint256 most = _larger(totalDebit, totalCredit);
        return most >= budget ? 0 : budget - most;
    }

    function _dust(bool isDeposit) internal pure returns (uint128) {
        return isDeposit ? DUST_ASSETS : DUST_SHARES;
    }
}
