// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {StandardsTargets} from "./StandardsTargets.sol";

import {D18} from "../../../../src/misc/types/D18.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice The instant vaults' previews and conversions asked for any `uint256`, from nothing through
///         `type(uint256).max`. A view takes a `uint256` but the vault books `uint128`, so an input has two honest
///         outcomes: an answer, or a revert with one of the arithmetic errors the amount's own size explains
///         (`Uint128_Overflow` from the 128-bit narrowing, `Int128_Overflow` from the policy's signed fee,
///         `MulDiv_Overflow` from the pricing product; `SPECIFICATION.md` marks the `uint128` revert of the views as a
///         deliberate `n`). A checked-arithmetic panic is allowed only on the two previews that add a fee to a
///         `uint128` (`previewMint`, `previewWithdraw`), where the sum itself can pass `uint128.max`. Anything else,
///         such as another custom error or an empty revert, is a defect in a path no integrator can predict.
///         Where it answers, it follows the preview rules (the fee, and only the fee, separates a preview from the
///         conversion; rounding runs against the caller; larger inputs never pay less or cost less).
abstract contract ExtremeAmountTargets is StandardsTargets {
    /// @dev What the largest fee (99.99%) can multiply a preview's amount by when it grosses it back up.
    uint256 internal constant BPS_FEE_FACTOR = 10_000;

    /// @dev What one view call came to: whether it answered, the answer, and the revert's selector.
    struct Quote {
        bool answered;
        uint256 value;
        bytes4 error;
        uint256 panicCode;
    }

    /// @dev The same views, asked of one amount: as an asset amount (`deposit`, `withdraw`, `convertToShares`) or as
    ///      a share amount (`mint`, `redeem`, `convertToAssets`).
    struct Views {
        Quote first;
        Quote second;
        Quote convert;
    }

    //----------------------------------------------------------------------------------------------
    // Handler and property
    //----------------------------------------------------------------------------------------------

    /// @dev Two amounts from the whole range, drawn from the classes that edge cases hide in (one unit, powers of
    ///      ten and their neighbours, the `int128` and `uint128` limits, the asset or share amount that converts to
    ///      exactly `uint128.max`, `uint256.max`), checked as an actor with nothing pending on both sides, while
    ///      the instant lane is open for it.
    function vault_extremeAmounts(uint256 actorSeed, bool basinVault, uint256 seedLow, uint256 seedHigh)
        public
        updateGhosts(OpType.USER)
    {
        IAsyncVault vault = vaults[basinVault ? 3 : 2];
        address actor = _actor(actorSeed);
        if (frozen[actor] || !_healthy(vault, actor) || !_instantPriced(vault)) return;
        if (_inAsync(vault, actor, true) || _inAsync(vault, actor, false)) return;

        uint256 low = _extremeAmount(seedLow);
        uint256 high = _extremeAmount(seedHigh);
        if (low > high) (low, high) = (high, low);

        (Views memory assetsLow, Views memory sharesLow) = _checkAmount(vault, actor, low);
        if (high != low) {
            (Views memory assetsHigh, Views memory sharesHigh) = _checkAmount(vault, actor, high);
            _checkMonotonic(assetsLow, assetsHigh, sharesLow, sharesHigh);
        }
        _ok("vault_extremeAmounts");
    }

    /// @dev The previews and conversions of both instant vaults at a fixed ladder of amounts, asked as an account
    ///      with nothing to claim: each is defined (see the contract), follows the preview rules, and the ladder,
    ///      which only rises, never pays or costs less as it climbs.
    function property_extremeAmountsAreDefined() public {
        if (!_oracleValid()) return;
        uint256[16] memory ladder = _ladder();
        for (uint256 v = 2; v < 4; v++) {
            IAsyncVault vault = vaults[v];
            if (!_instantPriced(vault)) continue;
            Views memory previousAssets;
            Views memory previousShares;
            for (uint256 i; i < ladder.length; i++) {
                (Views memory assets_, Views memory shares_) = _checkAmount(vault, PROBE, ladder[i]);
                if (i != 0) _checkMonotonic(previousAssets, assets_, previousShares, shares_);
                previousAssets = assets_;
                previousShares = shares_;
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Checks
    //----------------------------------------------------------------------------------------------

    /// @dev Everything the views owe at one amount `x`, read once as assets and once as shares.
    function _checkAmount(IAsyncVault vault, address caller, uint256 x)
        internal
        returns (Views memory assets_, Views memory shares_)
    {
        (, uint16 depositBps, uint16 redeemBps,,,,) = reserveInstantPolicy.config(address(vault));

        // x as an amount of assets: previewDeposit (deposit fee), previewWithdraw (redeem fee), convertToShares
        assets_ = Views({
            first: _view(vault, caller, vault.previewDeposit.selector, x),
            second: _view(vault, caller, vault.previewWithdraw.selector, x),
            convert: _view(vault, caller, vault.convertToShares.selector, x)
        });
        // x as an amount of shares: previewMint (deposit fee), previewRedeem (redeem fee), convertToAssets
        shares_ = Views({
            first: _view(vault, caller, vault.previewMint.selector, x),
            second: _view(vault, caller, vault.previewRedeem.selector, x),
            convert: _view(vault, caller, vault.convertToAssets.selector, x)
        });

        _definedOutcome(assets_.first, true, "previewDeposit", x, true);
        _definedOutcome(assets_.second, true, "previewWithdraw", x, true);
        _definedOutcome(assets_.convert, false, "convertToShares", x, true);
        _definedOutcome(shares_.first, true, "previewMint", x, false);
        _definedOutcome(shares_.second, true, "previewRedeem", x, false);
        _definedOutcome(shares_.convert, false, "convertToAssets", x, false);

        _checkAgainstConversion(assets_, shares_, depositBps, redeemBps);
        _checkRoundTrips(vault, caller, x, assets_, shares_);
    }

    /// @dev A preview is the conversion less the fee, rounded against the caller: `previewDeposit` and
    ///      `previewRedeem` are below the conversion, `previewMint` and `previewWithdraw` above it. At a fee of zero
    ///      the two floors are the same number, and the two ceilings are that number or the next one.
    function _checkAgainstConversion(Views memory assets_, Views memory shares_, uint16 depositBps, uint16 redeemBps)
        internal
    {
        if (assets_.first.answered && assets_.convert.answered) {
            lte(assets_.first.value, assets_.convert.value, "previewDeposit gave more than convertToShares");
        }
        if (assets_.second.answered && assets_.convert.answered) {
            gte(assets_.second.value, assets_.convert.value, "previewWithdraw cost less than convertToShares");
        }
        if (shares_.first.answered && shares_.convert.answered) {
            gte(shares_.first.value, shares_.convert.value, "previewMint cost less than convertToAssets");
        }
        if (shares_.second.answered && shares_.convert.answered) {
            lte(shares_.second.value, shares_.convert.value, "previewRedeem paid more than convertToAssets");
        }

        // With a fee the conversion's own gross loses (previewRedeem) or gains (previewMint) at least one unit to it
        if (redeemBps != 0 && shares_.second.answered && shares_.convert.answered && shares_.convert.value != 0) {
            lt(shares_.second.value, shares_.convert.value, "a redeem fee did not lower previewRedeem");
        }
        if (depositBps != 0 && shares_.first.answered && shares_.convert.answered && shares_.first.value != 0) {
            gt(shares_.first.value, shares_.convert.value, "a deposit fee did not raise previewMint");
        }

        // Without a fee the preview is the conversion: the same floor, so the same answer or the same refusal
        if (depositBps == 0) {
            t(
                assets_.first.answered == assets_.convert.answered,
                "at no deposit fee previewDeposit and convertToShares disagree on whether to answer"
            );
            if (assets_.first.answered) {
                eq(
                    assets_.first.value,
                    assets_.convert.value,
                    "at no deposit fee previewDeposit is not convertToShares"
                );
            }
            if (shares_.first.answered && shares_.convert.answered) {
                lte(shares_.first.value, shares_.convert.value + 1, "at no deposit fee previewMint is over a unit up");
            }
        }
        if (redeemBps == 0) {
            t(
                shares_.second.answered == shares_.convert.answered,
                "at no redeem fee previewRedeem and convertToAssets disagree on whether to answer"
            );
            if (shares_.second.answered) {
                eq(shares_.second.value, shares_.convert.value, "at no redeem fee previewRedeem is not convertToAssets");
            }
            if (assets_.second.answered && assets_.convert.answered) {
                lte(
                    assets_.second.value,
                    assets_.convert.value + 1,
                    "at no redeem fee previewWithdraw is over a unit up"
                );
            }
        }
    }

    /// @dev The roundtrips of the instant lane never gain, at any size: each is an inequality between previews,
    ///      asked only where both legs answer. Derived from the code: a floor then the inverse ceiling returns at most
    ///      the input, and a fee taken on the gross and grossed back up returns at most (or, for the exact-out
    ///      legs, at least) what was put in.
    function _checkRoundTrips(IAsyncVault vault, address caller, uint256 x, Views memory assets_, Views memory shares_)
        internal
    {
        // x assets in: deposit(x) shares, and what they cost to mint or pay out again, never more than x
        if (assets_.first.answered) {
            Quote memory minted = _view(vault, caller, vault.previewMint.selector, assets_.first.value);
            if (minted.answered) lte(minted.value, x, "minting what x assets deposit cost more than x");
            Quote memory redeemed = _view(vault, caller, vault.previewRedeem.selector, assets_.first.value);
            if (redeemed.answered) lte(redeemed.value, x, "a deposit then a redemption paid out more than went in");
        }
        // x assets out: withdraw(x) burns shares, and minting or redeeming them again returns at least x
        if (assets_.second.answered) {
            Quote memory minted = _view(vault, caller, vault.previewMint.selector, assets_.second.value);
            if (minted.answered) gte(minted.value, x, "withdrawing x then minting those shares cost less than x");
            Quote memory redeemed = _view(vault, caller, vault.previewRedeem.selector, assets_.second.value);
            if (redeemed.answered) {
                gte(redeemed.value, x, "withdrawing x then redeeming those shares paid less than x");
            }
        }
        // x shares redeemed: the assets, and what they deposit or burn to withdraw again, never more than x
        if (shares_.second.answered) {
            Quote memory deposited = _view(vault, caller, vault.previewDeposit.selector, shares_.second.value);
            if (deposited.answered) lte(deposited.value, x, "a redemption then a deposit returned more shares");
            Quote memory withdrawn = _view(vault, caller, vault.previewWithdraw.selector, shares_.second.value);
            if (withdrawn.answered) lte(withdrawn.value, x, "redeeming then withdrawing those assets burned more");
        }
        // x shares minted: the assets they cost, which deposit or withdraw back to at least x
        if (shares_.first.answered) {
            Quote memory deposited = _view(vault, caller, vault.previewDeposit.selector, shares_.first.value);
            if (deposited.answered) {
                gte(deposited.value, x, "minting x then depositing the cost returned fewer shares");
            }
            Quote memory withdrawn = _view(vault, caller, vault.previewWithdraw.selector, shares_.first.value);
            if (withdrawn.answered) gte(withdrawn.value, x, "minting x then withdrawing the cost burned fewer shares");
        }
    }

    /// @dev At a fixed price and fee every view is non-decreasing in its input, so a larger amount never pays or
    ///      costs less: `previewDeposit`, `previewRedeem` and the conversions floor a rising product, and the fee
    ///      taken on the gross (rounded up) or grossed back up never takes a rise away. Asked only where both answered.
    function _checkMonotonic(
        Views memory lowAssets,
        Views memory highAssets,
        Views memory lowShares,
        Views memory highShares
    ) internal {
        _rises(lowAssets.first, highAssets.first, "previewDeposit fell as the amount rose");
        _rises(lowAssets.second, highAssets.second, "previewWithdraw fell as the amount rose");
        _rises(lowAssets.convert, highAssets.convert, "convertToShares fell as the amount rose");
        _rises(lowShares.first, highShares.first, "previewMint fell as the amount rose");
        _rises(lowShares.second, highShares.second, "previewRedeem fell as the amount rose");
        _rises(lowShares.convert, highShares.convert, "convertToAssets fell as the amount rose");
    }

    function _rises(Quote memory low, Quote memory high, string memory reason) internal {
        if (low.answered && high.answered) lte(low.value, high.value, reason);
    }

    /// @dev An answer, or a revert from the defined set (see the contract), and only at an amount whose size explains
    ///      it: a conversion fits `uint128` up to `_convertibleLimit`, and a preview that adds the fee back loses at
    ///      most the factor the largest fee allows. The conversions revert on size alone, so neither the signed fee's
    ///      `Int128_Overflow` nor a panic is theirs.
    function _definedOutcome(Quote memory quote, bool isPreview, string memory name, uint256 x, bool inAssets)
        internal
    {
        if (quote.answered) return;
        bool defined = quote.error == MathLib.Uint128_Overflow.selector
            || quote.error == MathLib.MulDiv_Overflow.selector
            || (isPreview && quote.error == MathLib.Int128_Overflow.selector)
            || (isPreview && quote.error == PANIC && quote.panicCode == 0x11 && _mayOverflowWithFee(name));
        t(defined, string.concat(name, " reverted outside the defined arithmetic errors"));
        t(_sizeExplains(x, isPreview, inAssets), string.concat(name, " overflowed at a small amount"));
    }

    /// @dev Whether `x` is large enough to overflow: past what fits `uint128` itself or converts into it at the prices
    ///      (less the fee's factor for a preview), or at prices so far apart that their product cannot be formed, where any amount may.
    function _sizeExplains(uint256 x, bool isPreview, bool inAssets) internal view returns (bool) {
        (D18 ppa, D18 pps,) = spokeOracle.prices(poolA, scA, usdcId);
        if (ppa.raw() < 1e9 || ppa.raw() > 1e27 || pps.raw() < 1e9 || pps.raw() > 1e27) return true;
        uint256 limit = MathLib.min(_convertibleLimit(inAssets), type(uint128).max);
        return x > (isPreview ? limit / BPS_FEE_FACTOR : limit / 2);
    }

    /// @dev The two previews that add a fee to a `uint128` answer in `uint128`, so the sum may overflow it.
    function _mayOverflowWithFee(string memory name) internal pure returns (bool) {
        bytes32 h = keccak256(bytes(name));
        return h == keccak256("previewMint") || h == keccak256("previewWithdraw");
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    /// @dev The instant lane can price for a quote: the oracle vouches for both prices and the vault's policy is the
    ///      one whose fee the checks read.
    function _instantPriced(IAsyncVault vault) internal view returns (bool) {
        return _oracleValid() && address(vault.instantPolicy()) == address(reserveInstantPolicy);
    }

    /// @dev One view as `caller`, with the revert's selector (and a panic's code) kept.
    function _view(IAsyncVault vault, address caller, bytes4 selector, uint256 amount)
        internal
        returns (Quote memory quote)
    {
        vm.prank(caller);
        (bool success, bytes memory ret) = address(vault).staticcall(abi.encodeWithSelector(selector, amount));
        if (success) {
            quote.answered = ret.length == 32;
            if (quote.answered) quote.value = abi.decode(ret, (uint256));
            else quote.error = bytes4(0xdeadbeef);
            return quote;
        }
        if (ret.length >= 4) quote.error = bytes4(ret);
        if (quote.error == PANIC && ret.length >= 36) {
            uint256 code;
            assembly {
                code := mload(add(ret, 36))
            }
            quote.panicCode = code;
        }
    }

    /// @dev The ladder the property climbs, ascending: from nothing and one unit through the `int128` and `uint128`
    ///      limits (the sizes the signed fee and the 128-bit conversion refuse) to `uint256.max`.
    function _ladder() internal pure returns (uint256[16] memory ladder) {
        uint256 int128Max = uint256(uint128(type(int128).max));
        uint256 uint128Max = uint256(type(uint128).max);
        ladder = [
            uint256(0),
            1,
            2,
            1e6 - 1,
            1e6,
            1e18,
            1e24,
            1e30,
            1e36,
            int128Max,
            int128Max + 1,
            uint128Max - 1,
            uint128Max,
            uint128Max + 1,
            uint128Max * 2 ** 64,
            type(uint256).max
        ];
    }

    /// @dev An amount from `seed`, the class in the low bits: the unit, a power of ten with its neighbours, a limit
    ///      of `int128` or `uint128` with its neighbours, the one that converts to exactly `uint128.max` shares or
    ///      assets at the current prices (and the first past it), and a raw value.
    function _extremeAmount(uint256 seed) internal view returns (uint256) {
        uint256 kind = seed % 12;
        uint256 detail = seed / 12;
        int256 nudge = int256(detail % 5) - 2;
        uint256 base;
        if (kind == 0) {
            base = 1 + detail % 3;
        } else if (kind <= 3) {
            base = 10 ** (detail / 5 % 78);
        } else if (kind == 4) {
            base = uint256(uint128(type(int128).max));
        } else if (kind == 5) {
            base = uint256(type(uint128).max);
        } else if (kind == 6) {
            base = uint256(type(uint128).max) * (1 + detail / 5 % 2 ** 64);
        } else if (kind == 7) {
            base = type(uint256).max;
        } else if (kind == 8 || kind == 9) {
            base = _convertibleLimit(kind == 8);
        } else if (kind == 10) {
            base = ONE_ASSET * (1 + detail / 5 % 1_000_000_000);
        } else {
            return detail;
        }
        if (nudge < 0) {
            uint256 down = uint256(-nudge);
            return base > down ? base - down : 0;
        }
        uint256 up = uint256(nudge);
        return base > type(uint256).max - up ? type(uint256).max : base + up;
    }

    /// @dev The largest asset (or share) amount whose conversion fits `uint128`, or `uint128.max` when the prices are
    ///      too far apart for the product to be formed here.
    function _convertibleLimit(bool inAssets) internal view returns (uint256) {
        (D18 ppa, D18 pps,) = spokeOracle.prices(poolA, scA, usdcId);
        uint256 a = ppa.raw();
        uint256 s = pps.raw();
        uint256 most = uint256(type(uint128).max);
        if (a < 1e9 || a > 1e27 || s < 1e9 || s > 1e27) return most;
        return inAssets
            ? MathLib.mulDiv(most, 10 ** USDC_DECIMALS * s, 10 ** SHARE_DECIMALS * a, MathLib.Rounding.Down)
            : MathLib.mulDiv(most, 10 ** SHARE_DECIMALS * a, 10 ** USDC_DECIMALS * s, MathLib.Rounding.Down);
    }
}
