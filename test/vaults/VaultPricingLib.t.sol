// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18, d18} from "../../src/misc/types/D18.sol";
import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {PricingLib} from "../../src/core/libraries/PricingLib.sol";

import {InvestmentState} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {VaultPricingLib} from "../../src/vaults/libraries/VaultPricingLib.sol";

import "forge-std/Test.sol";

/// @notice The vault's pricing arithmetic against the definitions it implements: at the oracle's prices
///         `assets * ppa / 10^assetDecimals == shares * pps / 10^shareDecimals` in pool units, and at a
///         claim's price `assets / 10^assetDecimals == shares * price / 10^shareDecimals`, over every
///         decimals pair a registered asset and share token can have (0 to 18).
contract VaultPricingLibTest is Test {
    using MathLib for uint256;

    MathLib.Rounding constant DOWN = MathLib.Rounding.Down;
    MathLib.Rounding constant UP = MathLib.Rounding.Up;

    struct Setup {
        uint8 assetDecimals;
        uint8 shareDecimals;
        D18 ppa;
        D18 pps;
    }

    /// @dev Prices from 1e-9 to 1e9: past a 1e36 ratio between them, `clampToConvertible`'s own bound
    ///      overflows 256 bits and reverts, as it does in the vault.
    function _setup(uint8 assetDecimals, uint8 shareDecimals, uint128 ppa, uint128 pps)
        internal
        pure
        returns (Setup memory)
    {
        return Setup(
            uint8(bound(assetDecimals, 0, 18)),
            uint8(bound(shareDecimals, 0, 18)),
            d18(uint128(bound(ppa, 1e9, 1e27))),
            d18(uint128(bound(pps, 1e9, 1e27)))
        );
    }

    /// @dev The definition, in 512-bit-safe arithmetic: shares = assets * 10^sd * ppa / (10^ad * pps).
    function _sharesRef(uint256 assets, Setup memory s, MathLib.Rounding rounding) internal pure returns (uint256) {
        return
            MathLib.mulDiv(assets * 10 ** s.shareDecimals, s.ppa.raw(), 10 ** s.assetDecimals * s.pps.raw(), rounding);
    }

    function _assetsRef(uint256 shares, Setup memory s, MathLib.Rounding rounding) internal pure returns (uint256) {
        return
            MathLib.mulDiv(shares * 10 ** s.assetDecimals, s.pps.raw(), 10 ** s.shareDecimals * s.ppa.raw(), rounding);
    }

    //----------------------------------------------------------------------------------------------
    // Oracle prices
    //----------------------------------------------------------------------------------------------

    function testToSharesMatchesTheDefinition(
        uint128 assets,
        uint8 assetDecimals,
        uint8 shareDecimals,
        uint128 ppa,
        uint128 pps,
        bool up
    ) public pure {
        Setup memory s = _setup(assetDecimals, shareDecimals, ppa, pps);
        MathLib.Rounding rounding = up ? UP : DOWN;
        uint256 expected = _sharesRef(assets, s, rounding);
        vm.assume(expected <= type(uint128).max);

        assertEq(VaultPricingLib.toShares(assets, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, rounding), expected);
    }

    function testToAssetsMatchesTheDefinition(
        uint128 shares,
        uint8 assetDecimals,
        uint8 shareDecimals,
        uint128 ppa,
        uint128 pps,
        bool up
    ) public pure {
        Setup memory s = _setup(assetDecimals, shareDecimals, ppa, pps);
        MathLib.Rounding rounding = up ? UP : DOWN;
        uint256 expected = _assetsRef(shares, s, rounding);
        vm.assume(expected <= type(uint128).max);

        assertEq(VaultPricingLib.toAssets(shares, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, rounding), expected);
    }

    /// @dev Rounding up never gives less than rounding down, and at most one unit more.
    function testRoundingDirection(uint128 amount, uint8 assetDecimals, uint8 shareDecimals, uint128 ppa, uint128 pps)
        public
        pure
    {
        Setup memory s = _setup(assetDecimals, shareDecimals, ppa, pps);
        uint128 assets = uint128(
            bound(
                amount,
                0,
                VaultPricingLib.clampToConvertible(type(uint128).max, s.assetDecimals, s.shareDecimals, s.ppa, s.pps)
            )
        );
        vm.assume(_sharesRef(assets, s, UP) <= type(uint128).max);

        uint128 down = VaultPricingLib.toShares(assets, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, DOWN);
        uint128 up = VaultPricingLib.toShares(assets, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, UP);
        assertLe(down, up);
        assertLe(up - down, 1);
    }

    /// @dev Converting there and back, rounding down both ways, never creates value; rounding up both
    ///      ways never loses it. These are the directions the vault rounds a payout and a charge.
    function testRoundTrips(uint128 amount, uint8 assetDecimals, uint8 shareDecimals, uint128 ppa, uint128 pps)
        public
        pure
    {
        Setup memory s = _setup(assetDecimals, shareDecimals, ppa, pps);
        uint128 assets = uint128(
            bound(
                amount,
                0,
                VaultPricingLib.clampToConvertible(type(uint128).max, s.assetDecimals, s.shareDecimals, s.ppa, s.pps)
            )
        );

        uint128 sharesDown = VaultPricingLib.toShares(assets, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, DOWN);
        assertLe(VaultPricingLib.toAssets(sharesDown, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, DOWN), assets);

        vm.assume(_sharesRef(assets, s, UP) <= type(uint128).max);
        uint128 sharesUp = VaultPricingLib.toShares(assets, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, UP);
        vm.assume(_assetsRef(sharesUp, s, UP) <= type(uint128).max);
        assertGe(VaultPricingLib.toAssets(sharesUp, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, UP), assets);
    }

    /// @dev A role check's estimate is the conversion where it fits, saturates where it does not, and reads as the
    ///      most there is while a price is unset, so a hook that limits it refuses rather than passes.
    function testEstimatesMatchTheConversionWhereItFits(
        uint128 amount,
        uint8 assetDecimals,
        uint8 shareDecimals,
        uint128 ppa,
        uint128 pps
    ) public pure {
        Setup memory s = _setup(assetDecimals, shareDecimals, ppa, pps);
        uint256 shares = _sharesRef(amount, s, DOWN);
        uint256 assets = _assetsRef(amount, s, DOWN);
        assertEq(
            VaultPricingLib.sharesEstimate(amount, s.assetDecimals, s.shareDecimals, s.ppa, s.pps),
            MathLib.min(shares, type(uint128).max)
        );
        assertEq(
            VaultPricingLib.assetsEstimate(amount, s.assetDecimals, s.shareDecimals, s.ppa, s.pps),
            MathLib.min(assets, type(uint128).max)
        );
    }

    function testEstimatesAreUnlimitedBeforeTheFirstPrice() public pure {
        assertEq(VaultPricingLib.sharesEstimate(1e6, 6, 18, d18(1e18), d18(0)), type(uint128).max);
        assertEq(VaultPricingLib.sharesEstimate(1e6, 6, 18, d18(0), d18(1e18)), type(uint128).max);
        assertEq(VaultPricingLib.assetsEstimate(1e18, 6, 18, d18(0), d18(1e18)), type(uint128).max);
        assertEq(VaultPricingLib.sharesEstimate(0, 6, 18, d18(1e18), d18(0)), 0, "nothing is worth nothing");
    }

    /// @dev The divisor price is the caller's to check: a zero one reverts rather than reading as zero.
    function testZeroDivisorPriceReverts() public {
        vm.expectRevert(PricingLib.DivisionByZero.selector);
        this.toShares(1e6, 6, 18, d18(1e18), d18(0));

        vm.expectRevert(PricingLib.DivisionByZero.selector);
        this.toAssets(1e18, 6, 18, d18(0), d18(1e18));
    }

    function testZeroNumeratorPriceIsZero() public pure {
        assertEq(VaultPricingLib.toShares(1e6, 6, 18, d18(0), d18(1e18), UP), 0);
        assertEq(VaultPricingLib.toAssets(1e18, 6, 18, d18(1e18), d18(0), UP), 0);
    }

    function testKnownValues() public pure {
        // 1 USDC (6 decimals) at ppa 1 and pps 2 buys half an 18-decimal share.
        assertEq(VaultPricingLib.toShares(1e6, 6, 18, d18(1e18), d18(2e18), DOWN), 5e17);
        assertEq(VaultPricingLib.toAssets(5e17, 6, 18, d18(1e18), d18(2e18), DOWN), 1e6);
        // A third, rounded each way.
        assertEq(VaultPricingLib.toShares(1, 0, 0, d18(1e18), d18(3e18), DOWN), 0);
        assertEq(VaultPricingLib.toShares(1, 0, 0, d18(1e18), d18(3e18), UP), 1);
    }

    //----------------------------------------------------------------------------------------------
    // Convertible capacity
    //----------------------------------------------------------------------------------------------

    /// @dev The clamp keeps the capacity where it can, and what it returns always converts.
    function testClampConverts(uint128 capacity, uint8 assetDecimals, uint8 shareDecimals, uint128 ppa, uint128 pps)
        public
        pure
    {
        Setup memory s = _setup(assetDecimals, shareDecimals, ppa, pps);
        uint128 clamped = VaultPricingLib.clampToConvertible(capacity, s.assetDecimals, s.shareDecimals, s.ppa, s.pps);

        assertLe(clamped, capacity);
        assertLe(_sharesRef(clamped, s, DOWN), type(uint128).max);
        if (_sharesRef(capacity, s, DOWN) <= type(uint128).max) assertEq(clamped, capacity, "clamped what converts");
    }

    /// @dev A clamp to the room a supply has left keeps the capacity where it can, and what it returns mints no more
    ///      shares than that room: shares are issued on top of the supply, so the room is what `uint128` has left.
    function testClampToSharesKeepsWithinTheRoom(
        uint128 capacity,
        uint8 assetDecimals,
        uint8 shareDecimals,
        uint128 ppa,
        uint128 pps,
        uint128 supply
    ) public pure {
        Setup memory s = _setup(assetDecimals, shareDecimals, ppa, pps);
        uint256 room = type(uint128).max - supply;
        uint128 clamped = VaultPricingLib.clampToShares(capacity, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, room);

        assertLe(clamped, capacity);
        assertLe(_sharesRef(clamped, s, DOWN), room, "the shares fit on top of the supply");
        // With no room a deposit has nothing to mint (it would revert as a zero amount), so no capacity is offered even
        // for an amount that converts to no shares
        if (room == 0) {
            assertEq(clamped, 0, "no room, no capacity");
        } else if (_sharesRef(capacity, s, DOWN) <= room) {
            // The room is rounded down to whole assets, so a capacity that fits can read short, but by less than what
            // one share is worth: the clamp never offers more than fits, and loses at most the rounding
            assertLe(capacity - clamped, _assetsRef(1, s, UP), "clamped what fits, less one share's rounding");
        }
        assertEq(
            VaultPricingLib.clampToShares(capacity, s.assetDecimals, s.shareDecimals, s.ppa, s.pps, type(uint128).max),
            VaultPricingLib.clampToConvertible(capacity, s.assetDecimals, s.shareDecimals, s.ppa, s.pps),
            "an empty supply is the plain clamp"
        );
    }

    /// @dev The decimals form the vault uses agrees with core's token-reading form.
    function testMaxConvertibleMatchesCorePricing(uint128 pps, uint128 ppa) public {
        pps = uint128(bound(pps, 1, 1e30));
        ppa = uint128(bound(ppa, 1, 1e30));
        MockERC20 asset = new MockERC20(6);
        MockShareToken share = new MockShareToken(18);

        assertEq(
            VaultPricingLib.maxConvertibleAssetAmount(6, 18, type(uint128).max, D18.wrap(pps), D18.wrap(ppa)),
            PricingLib.maxConvertibleAssetAmount(
                address(share), address(asset), 0, type(uint128).max, D18.wrap(pps), D18.wrap(ppa)
            )
        );
    }

    function testClampIsZeroWithoutAPrice(uint128 capacity) public pure {
        assertEq(VaultPricingLib.clampToConvertible(capacity, 6, 18, d18(0), d18(1e18)), 0);
        assertEq(VaultPricingLib.clampToConvertible(capacity, 6, 18, d18(1e18), d18(0)), 0);
        assertEq(VaultPricingLib.clampToConvertible(0, 6, 18, d18(1e18), d18(1e18)), 0);
    }

    //----------------------------------------------------------------------------------------------
    // External entry points, so a revert can be expected
    //----------------------------------------------------------------------------------------------

    function toShares(uint128 assets, uint8 assetDecimals, uint8 shareDecimals, D18 ppa, D18 pps)
        external
        pure
        returns (uint128)
    {
        return VaultPricingLib.toShares(assets, assetDecimals, shareDecimals, ppa, pps, DOWN);
    }

    function toAssets(uint128 shares, uint8 assetDecimals, uint8 shareDecimals, D18 ppa, D18 pps)
        external
        pure
        returns (uint128)
    {
        return VaultPricingLib.toAssets(shares, assetDecimals, shareDecimals, ppa, pps, DOWN);
    }
}

/// @dev A storage home for the claimable ledger, credited the way a fold credits it.
contract InvestmentStateHarness {
    InvestmentState public state;

    function accumulateDeposit(uint128 shares, uint128 assets) external {
        state.depositShares += shares;
        state.depositAssets += assets;
    }

    function accumulateRedeem(uint128 shares, uint128 assets) external {
        state.redeemAssets += assets;
        state.redeemShares += shares;
    }
}

/// @dev The claimable ledger keeps exact totals per side and a claim converts pro-rata against them.
contract VaultPricingLibLedgerTest is Test {
    MathLib.Rounding constant DOWN = MathLib.Rounding.Down;
    MathLib.Rounding constant UP = MathLib.Rounding.Up;

    InvestmentStateHarness h;

    function setUp() public {
        h = new InvestmentStateHarness();
    }

    /// @dev Both units of every fill are kept, so the ledger is order-independent.
    function testAccumulationKeepsExactTotals(uint64 shares1, uint64 assets1, uint64 shares2, uint64 assets2) public {
        h.accumulateDeposit(shares1, assets1);
        h.accumulateDeposit(shares2, assets2);
        h.accumulateRedeem(shares2, assets2);
        h.accumulateRedeem(shares1, assets1);
        (uint128 maxMint, uint128 depositAssets, uint128 maxWithdraw, uint128 redeemShares,,) = h.state();
        assertEq(maxMint, uint128(shares1) + shares2);
        assertEq(depositAssets, uint128(assets1) + assets2);
        assertEq(maxWithdraw, uint128(assets1) + assets2);
        assertEq(redeemShares, uint128(shares1) + shares2);
    }

    function testSliceOfTheWholeBalanceIsTheWholeCounter(uint128 total, uint128 counter) public pure {
        total = uint128(bound(total, 1, type(uint128).max));
        assertEq(uint128(MathLib.fractionOf(counter, total, total, DOWN)), counter);
        assertEq(uint128(MathLib.fractionOf(counter, total, total, UP)), counter);
        assertEq(uint128(MathLib.fractionOf(counter, 0, total, UP)), 0);
    }

    function testSliceIsProRata(uint128 part, uint128 total, uint128 counter) public pure {
        total = uint128(bound(total, 1, type(uint128).max));
        part = uint128(bound(part, 1, total));
        uint256 exactDown = MathLib.mulDiv(part, counter, total, DOWN);
        uint256 exactUp = MathLib.mulDiv(part, counter, total, UP);
        if (part == total) return;
        assertEq(uint128(MathLib.fractionOf(counter, part, total, DOWN)), exactDown);
        assertEq(uint128(MathLib.fractionOf(counter, part, total, UP)), exactUp);
        assertLe(exactUp, counter, "a slice never exceeds the counter");
    }

    /// @dev Claiming a balance in any number of pieces pays out exactly the counter-unit in total, and
    ///      never more along the way: what each floor leaves behind is taken by the last piece.
    function testPiecewiseClaimsPayExactlyTheCounter(uint128 total, uint128 counter, uint64[6] memory pieces)
        public
        pure
    {
        total = uint128(bound(total, 1, type(uint128).max / 2));
        counter = uint128(bound(counter, 0, type(uint128).max / 2));
        uint128 left = total;
        uint128 counterLeft = counter;
        uint256 paid;
        for (uint256 i; i < pieces.length && left > 0; i++) {
            uint128 piece = uint128(bound(pieces[i], 1, left));
            uint128 out = uint128(MathLib.fractionOf(counterLeft, piece, left, DOWN));
            paid += out;
            left -= piece;
            counterLeft -= out;
            assertLe(paid, counter, "paid more than the counter");
        }
        paid += uint128(MathLib.fractionOf(counterLeft, left, left, DOWN));
        assertEq(paid, counter, "the pieces did not add up to the counter");
    }
}
