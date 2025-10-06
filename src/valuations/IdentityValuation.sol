// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IIdentityValuation} from "./interfaces/IIdentityValuation.sol";

import {d18, D18} from "../misc/types/D18.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {PricingLib} from "../core/libraries/PricingLib.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IValuation} from "../core/hub/interfaces/IValuation.sol";
import {IHubRegistry} from "../core/hub/interfaces/IHubRegistry.sol";

/// @title  IdentityValuation
/// @notice This contract provides a 1:1 valuation implementation that always returns a price of 1.0,
///         performing only decimal conversion between assets and pool currency without any price
///         adjustments, suitable for stablecoins or pegged assets.
contract IdentityValuation is IIdentityValuation {
    IHubRegistry public immutable hubRegistry;

    constructor(IHubRegistry hubRegistry_) {
        hubRegistry = hubRegistry_;
    }

    /// @inheritdoc IValuation
    function getPrice(PoolId, ShareClassId, AssetId) external pure returns (D18) {
        return d18(1e18);
    }

    /// @inheritdoc IValuation
    function getQuote(PoolId poolId, ShareClassId, AssetId assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount)
    {
        return PricingLib.convertWithPrice(
            baseAmount, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), d18(1e18)
        );
    }
}
