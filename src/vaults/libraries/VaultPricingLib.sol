// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../misc/types/D18.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";

import {PricingLib} from "../../core/libraries/PricingLib.sol";

/// @title  Vault Pricing Lib
/// @notice The vault's pricing arithmetic: conversions at the oracle's pool prices (`ppa`, `pps`) for the
///         instant lane and the ERC-4626 views, the instant lane's signed fees, and the claimable ledger
///         the async claims are paid from. The ledger keeps exact totals per side (claimable units and
///         the counter-units they were filled for), and a claim converts pro-rata against them, so it is
///         order-independent and a claim of the whole balance takes exactly what is left.
library VaultPricingLib {
    using MathLib for uint256;

    /// @notice Shares worth `assets` at the oracle's prices. Reverts on a zero `pps`.
    function toShares(
        uint128 assets,
        uint8 assetDecimals,
        uint8 shareDecimals,
        D18 ppa,
        D18 pps,
        MathLib.Rounding rounding
    ) internal pure returns (uint128) {
        return PricingLib.assetToShareAmount(assets, assetDecimals, shareDecimals, ppa, pps, rounding);
    }

    /// @notice Assets worth `shares` at the oracle's prices. Reverts on a zero `ppa`.
    function toAssets(
        uint128 shares,
        uint8 assetDecimals,
        uint8 shareDecimals,
        D18 ppa,
        D18 pps,
        MathLib.Rounding rounding
    ) internal pure returns (uint128) {
        return PricingLib.shareToAssetAmount(shares, shareDecimals, assetDecimals, pps, ppa, rounding);
    }

    /// @notice The shares `assets` are worth, for a role check that has no exact figure: saturating at
    ///         `type(uint128).max`, which is also the answer while a price is unset, so an unknown figure never reads
    ///         as small to a hook that limits it.
    function sharesEstimate(uint128 assets, uint8 assetDecimals, uint8 shareDecimals, D18 ppa, D18 pps)
        internal
        pure
        returns (uint128)
    {
        return _estimate(assets, assetDecimals, shareDecimals, ppa, pps);
    }

    /// @notice The assets `shares` are worth, as `sharesEstimate`.
    function assetsEstimate(uint128 shares, uint8 assetDecimals, uint8 shareDecimals, D18 ppa, D18 pps)
        internal
        pure
        returns (uint128)
    {
        return _estimate(shares, shareDecimals, assetDecimals, pps, ppa);
    }

    /// @notice Clamps an asset `capacity` to what converts to shares without overflowing uint128. Zero
    ///         when a price is unset.
    function clampToConvertible(uint128 capacity, uint8 assetDecimals, uint8 shareDecimals, D18 ppa, D18 pps)
        internal
        pure
        returns (uint128)
    {
        return clampToShares(capacity, assetDecimals, shareDecimals, ppa, pps, type(uint128).max);
    }

    /// @notice As `clampToConvertible`, for a conversion that may mint at most `maxShares`: what the share supply
    ///         has room for, since the shares are issued on top of those already in it.
    function clampToShares(
        uint128 capacity,
        uint8 assetDecimals,
        uint8 shareDecimals,
        D18 ppa,
        D18 pps,
        uint256 maxShares
    ) internal pure returns (uint128) {
        if (capacity == 0 || pps.isZero() || ppa.isZero()) return 0;
        uint256 maxConvertible = maxConvertibleAssetAmount(assetDecimals, shareDecimals, maxShares, pps, ppa);
        return MathLib.min(capacity, maxConvertible).toUint128();
    }

    /// @notice The largest asset amount that converts to at most `maxShares` at the given prices, so a
    ///         capacity clamped to it cannot overflow the uint128 share conversion.
    function maxConvertibleAssetAmount(
        uint8 assetDecimals,
        uint8 shareDecimals,
        uint256 maxShares,
        D18 pricePoolPerShare,
        D18 pricePoolPerAsset
    ) internal pure returns (uint256) {
        return MathLib.mulDiv(
            maxShares,
            uint256(10 ** assetDecimals) * pricePoolPerShare.raw(),
            uint256(10 ** shareDecimals) * pricePoolPerAsset.raw(),
            MathLib.Rounding.Down
        );
    }

    function _estimate(uint128 amount, uint8 fromDecimals, uint8 toDecimals, D18 priceFrom, D18 priceTo)
        private
        pure
        returns (uint128)
    {
        if (amount == 0) return 0;
        if (priceFrom.isZero() || priceTo.isZero()) return type(uint128).max;
        uint256 value = MathLib.mulDiv(
            priceFrom.raw(),
            10 ** toDecimals * uint256(amount),
            10 ** fromDecimals * uint256(priceTo.raw()),
            MathLib.Rounding.Down
        );
        return value > type(uint128).max ? type(uint128).max : uint128(value);
    }
}
