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
import {IManagerCallFromHub, IManagerCallFromSpoke} from "../core/utils/interfaces/IManagerCall.sol";

/// @title  OracleValuation
/// @notice Provides an implementation for valuation of assets by trusted price feeders.
///         Prices should be denominated in the pool currency.
///         Quorum is always 1, i.e. there is no aggregation of prices across multiple feeders.
/// @dev    Setup: add feeders via `fromHub` (`hub.managerCall` -> `Envoy`, policy-supervised), set this
///         contract as the valuation for one or more assets, and rely it as a hub manager to call
///         `hub.updateHoldingValue()`. Price updates: local via `setPrice()`, remote via `fromSpoke()`
///         (`spoke.managerCall` -> `Envoy`); both validate the caller against the `feeder` mapping.
contract OracleValuation is IOracleValuation {
    using CastLib for *;

    /// @dev centrifugeId used for local feeders (as opposed to remote/cross-chain feeders).
    uint16 public constant LOCAL = 0;

    IHub public immutable hub;
    address public immutable envoy;
    IHubRegistry public immutable hubRegistry;

    /// @dev centrifugeId=LOCAL for local feeders, otherwise the source chain ID for remote feeders.
    mapping(PoolId => mapping(uint16 centrifugeId => mapping(bytes32 => bool))) public feeder;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId base => Price))) public pricePoolPerAsset;

    constructor(IHub hub_, IHubRegistry hubRegistry_, address envoy_) {
        hub = hub_;
        hubRegistry = hubRegistry_;
        envoy = envoy_;
    }

    //----------------------------------------------------------------------------------------------
    // Hub actions
    //----------------------------------------------------------------------------------------------

    /// @dev The Envoy is the only authorized caller of `fromHub`/`fromSpoke`, and neither forwards value.
    modifier onlyEnvoy() {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());
        _;
    }

    /// @inheritdoc IManagerCallFromHub
    /// @dev Adds/removes a price feeder. No outgoing message, so value is rejected.
    ///      Feeder details are encoded in `payload` (single action, no discriminator).
    function fromHub(PoolId poolId, bytes calldata payload) external payable onlyEnvoy {
        (uint16 centrifugeId, bytes32 feeder_, bool canFeed) = abi.decode(payload, (uint16, bytes32, bool));
        feeder[poolId][centrifugeId][feeder_] = canFeed;
        emit UpdateFeeder(poolId, centrifugeId, feeder_, canFeed);
    }

    //----------------------------------------------------------------------------------------------
    // Update price
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IOracleValuation
    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external {
        require(feeder[poolId][LOCAL][msg.sender.toBytes32()], NotFeeder());
        _setPrice(poolId, scId, assetId, newPrice);
    }

    /// @inheritdoc IManagerCallFromSpoke
    /// @dev Remote price update by a registered feeder. No outgoing message, so value is rejected.
    ///      The share class id is encoded in `payload` (fromSpoke carries no scId).
    function fromSpoke(PoolId poolId, bytes calldata payload, uint16 centrifugeId, bytes32 sender)
        external
        payable
        onlyEnvoy
    {
        require(feeder[poolId][centrifugeId][sender], NotFeeder());

        (bytes16 scId, AssetId assetId, uint128 newPrice, uint64 priceAt) =
            abi.decode(payload, (bytes16, AssetId, uint128, uint64));
        require(assetId.centrifugeId() == centrifugeId, NetworkMismatch());
        uint64 lastUpdatedAt = pricePoolPerAsset[poolId][ShareClassId.wrap(scId)][assetId].updatedAt;
        require(priceAt > lastUpdatedAt, StalePrice());

        _setPrice(poolId, ShareClassId.wrap(scId), assetId, D18.wrap(newPrice));
    }

    function _setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) internal {
        pricePoolPerAsset[poolId][scId][assetId] = Price(newPrice, true, uint64(block.timestamp));
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
