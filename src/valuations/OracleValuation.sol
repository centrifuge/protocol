// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOracleValuation} from "./interfaces/IOracleValuation.sol";

import {D18} from "../misc/types/D18.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {IHub} from "../core/hub/interfaces/IHub.sol";
import {PricingLib} from "../core/libraries/PricingLib.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IValuation} from "../core/interfaces/IValuation.sol";
import {IHubRegistry} from "../core/hub/interfaces/IHubRegistry.sol";

/// @notice Provides an implementation for valuation of assets by trusted price feeders.
///         Prices should be denominated in the pool currency.
///         Quorum is always 1, i.e. there is no aggregation of prices across multiple feeders.
/// @dev    To set up, add a price feeder using hub.updateFeeder(), set this contract as the valuation
///         for one or more assets, and set this contract as a hub manager, so it can call
///         hub.updateHoldingValue().
contract OracleValuation is IOracleValuation {
    IHub public immutable hub;
    IHubRegistry public immutable hubRegistry;

    mapping(PoolId => mapping(address => bool)) public feeder;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId base => Price))) public pricePoolPerAsset;

    constructor(IHub hub_, IHubRegistry hubRegistry_) {
        hub = hub_;
        hubRegistry = hubRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleValuation
    function updateFeeder(PoolId poolId, address feeder_, bool canFeed) external {
        require(hubRegistry.manager(poolId, msg.sender), NotHubManager());
        feeder[poolId][feeder_] = canFeed;
        emit UpdateFeeder(poolId, feeder_, canFeed);
    }

    //----------------------------------------------------------------------------------------------
    // Update price
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleValuation
    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external {
        require(feeder[poolId][msg.sender], NotFeeder());

        pricePoolPerAsset[poolId][scId][assetId] = Price(newPrice, true);
        hub.updateHoldingValue(poolId, scId, assetId);

        emit UpdatePrice(poolId, scId, assetId, newPrice);
    }

    //----------------------------------------------------------------------------------------------
    // Read price
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IValuation
    function getPrice(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (D18) {
        Price memory price = pricePoolPerAsset[poolId][scId][assetId];
        require(price.isValid, PriceNotSet());

        return price.value;
    }

    /// @inheritdoc IValuation
    function getQuote(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount)
    {
        return PricingLib.convertWithPrice(
            baseAmount, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), getPrice(poolId, scId, assetId)
        );
    }
}
