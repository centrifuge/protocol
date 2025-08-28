// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOracleValuation} from "./interfaces/IOracleValuation.sol";

import {D18} from "../misc/types/D18.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";

import {IHub} from "../hub/interfaces/IHub.sol";
import {IHubRegistry} from "../hub/interfaces/IHubRegistry.sol";

/// @notice Provides an implementation for valuation of assets by trusted price feeders.
///         Quorum is always 1, i.e. there is no aggregation of prices across multiple feeders.
///         If a price is fed with the pool currency as the quote asset, the holding value is updated.
/// @dev    To set up, add a price feeder using hub.updateContract(), set this contract as the valuation
///         for one or more assets, and set this contract as a hub manager, so it can call
///         hub.updateHoldingValue().
contract OracleValuation is IOracleValuation {
    event UpdatePrice(
        PoolId indexed poolId, ShareClassId scId, AssetId indexed base, AssetId indexed quote, D18 newPrice
    );

    error NotFeeder();
    error NotHubManager();

    IHub public immutable hub;
    address public immutable contractUpdater;
    IHubRegistry public immutable hubRegistry;
    uint16 public immutable localCentrifugeId;

    mapping(PoolId => mapping(address => bool)) public feeder;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId base => mapping(AssetId quote => D18)))) public price;

    constructor(
        IHub hub_,
        address contractUpdater_,
        IHubRegistry hubRegistry_,
        uint16 localCentrifugeId_,
        address deployer
    ) {
        hub = hub_;
        contractUpdater = contractUpdater_;
        hubRegistry = hubRegistry_;
        localCentrifugeId = localCentrifugeId_;
    }

    function updateFeeder(PoolId poolId, address feeder_, bool canFeed) external {
        require(hubRegistry.manager(poolId, msg.sender), NotHubManager());
        feeder[poolId][feeder_] = canFeed;
    }

    // TODO: updateContract to update price manager
    // Check poolId.centrifugeId() == localCentrifugeId, since this is only intended to be used on hub chains

    function setPrice(PoolId poolId, ShareClassId scId, AssetId base, AssetId quote, D18 newPrice) external {
        require(feeder[poolId][msg.sender], NotFeeder());

        price[poolId][scId][base][quote] = newPrice;
        if (quote == hubRegistry.currency(poolId)) hub.updateHoldingValue(poolId, scId, base);

        emit UpdatePrice(poolId, scId, base, quote, newPrice);
    }

    /// @inheritdoc IValuation
    function getQuote(uint128 baseAmount, AssetId base, AssetId quote) external view returns (uint128 quoteAmount) {
        return PricingLib.convertWithPrice(
            baseAmount, hubRegistry.decimals(base.raw()), hubRegistry.decimals(quote.raw()), price[]
        );
    }
}
