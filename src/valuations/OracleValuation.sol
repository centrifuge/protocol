// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IOracleValuation} from "./interfaces/IOracleValuation.sol";

import {D18} from "../misc/types/D18.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {IHub} from "../core/hub/interfaces/IHub.sol";
import {PricingLib} from "../core/libraries/PricingLib.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IValuation} from "../core/hub/interfaces/IValuation.sol";
import {IHubRegistry} from "../core/hub/interfaces/IHubRegistry.sol";
import {IUntrustedContractUpdate} from "../core/utils/interfaces/IContractUpdate.sol";

/// @title  OracleValuation
/// @notice Provides an implementation for valuation of assets by trusted price feeders.
///         Prices should be denominated in the pool currency.
///         Quorum is always 1, i.e. there is no aggregation of prices across multiple feeders.
/// @dev    To set up, add a price feeder using `updateFeeder()`, set this contract as the valuation
///         for one or more assets, and set this contract as a hub manager, so it can call
///         `hub.updateHoldingValue()`.
///         Supports both local calls via `setPrice()` and remote calls via `untrustedCall()`
///         from spoke-side executors. Both paths validate the caller against the `feeder` mapping.
contract OracleValuation is IOracleValuation, IUntrustedContractUpdate {
    using CastLib for *;

    /// @dev centrifugeId used for local feeders (as opposed to remote/cross-chain feeders).
    uint16 public constant LOCAL = 0;

    IHub public immutable hub;
    address public immutable contractUpdater;
    IHubRegistry public immutable hubRegistry;

    /// @dev centrifugeId=LOCAL for local feeders, otherwise the source chain ID for remote feeders.
    mapping(PoolId => mapping(uint16 centrifugeId => mapping(address => bool))) public feeder;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId base => Price))) public pricePoolPerAsset;

    constructor(IHub hub_, IHubRegistry hubRegistry_, address contractUpdater_) {
        hub = hub_;
        hubRegistry = hubRegistry_;
        contractUpdater = contractUpdater_;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleValuation
    function updateFeeder(PoolId poolId, uint16 centrifugeId, address feeder_, bool canFeed) external {
        require(hubRegistry.manager(poolId, msg.sender), NotHubManager());
        feeder[poolId][centrifugeId][feeder_] = canFeed;
        emit UpdateFeeder(poolId, centrifugeId, feeder_, canFeed);
    }

    //----------------------------------------------------------------------------------------------
    // Update price
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleValuation
    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external {
        require(feeder[poolId][LOCAL][msg.sender], NotFeeder());
        _setPrice(poolId, scId, assetId, newPrice);
    }

    /// @inheritdoc IUntrustedContractUpdate
    function untrustedCall(
        PoolId poolId,
        ShareClassId scId,
        bytes calldata payload,
        uint16 centrifugeId,
        bytes32 sender
    ) external {
        require(msg.sender == contractUpdater, NotAuthorized());
        require(feeder[poolId][centrifugeId][sender.toAddress()], NotFeeder());
        (uint128 assetId, uint128 newPrice) = abi.decode(payload, (uint128, uint128));
        _setPrice(poolId, scId, AssetId.wrap(assetId), D18.wrap(newPrice));
    }

    function _setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) internal {
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
