// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOracleValuation} from "./interfaces/IOracleValuation.sol";

import {D18} from "../misc/types/D18.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";

import {IHub} from "../hub/interfaces/IHub.sol";
import {IHubRegistry} from "../hub/interfaces/IHubRegistry.sol";

/// @notice Provides an implementation for valuation of assets by trusted price feeders.
///         Prices should be denominated in the pool currency.
///         Quorum is always 1, i.e. there is no aggregation of prices across multiple feeders.
/// @dev    To set up, add a price feeder using hub.updateContract(), set this contract as the valuation
///         for one or more assets, and set this contract as a hub manager, so it can call
///         hub.updateHoldingValue().
contract OracleValuation is IOracleValuation {
    IHub public immutable hub;
    address public immutable contractUpdater;
    IHubRegistry public immutable hubRegistry;
    uint16 public immutable localCentrifugeId;

    mapping(PoolId => mapping(address => bool)) public feeder;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId base => Price))) public price;

    constructor(IHub hub_, address contractUpdater_, IHubRegistry hubRegistry_, uint16 localCentrifugeId_) {
        hub = hub_;
        contractUpdater = contractUpdater_;
        hubRegistry = hubRegistry_;
        localCentrifugeId = localCentrifugeId_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleValuation
    function updateFeeder(PoolId poolId, address feeder_, bool canFeed) external {
        require(hubRegistry.manager(poolId, msg.sender), NotHubManager());
        feeder[poolId][feeder_] = canFeed;
    }

    //----------------------------------------------------------------------------------------------
    // Update price
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleValuation
    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external {
        require(feeder[poolId][msg.sender], NotFeeder());

        price[poolId][scId][assetId] = Price(newPrice, true);
        hub.updateHoldingValue(poolId, scId, assetId);

        emit UpdatePrice(poolId, scId, assetId, newPrice);
    }

    //----------------------------------------------------------------------------------------------
    // Read price
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IValuation
    function getQuote(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount)
    {
        Price memory price_ = price[poolId][scId][assetId];
        require(price_.isValid, PriceNotSet());

        return PricingLib.convertWithPrice(
            baseAmount, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), price_.value
        );
    }
}
