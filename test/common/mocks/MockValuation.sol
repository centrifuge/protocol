// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../../src/misc/types/D18.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {PricingLib} from "../../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IValuation} from "../../../src/core/interfaces/IValuation.sol";

import {IHubRegistry} from "../../../src/core/hub/interfaces/IHubRegistry.sol";

struct Price {
    D18 value;
    bool isValid;
}

contract MockValuation is IValuation {
    using MathLib for *;

    IHubRegistry hubRegistry;
    mapping(PoolId => mapping(ShareClassId => mapping(AssetId base => Price))) public price;

    constructor(IHubRegistry hubRegistry_) {
        hubRegistry = hubRegistry_;
    }

    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external {
        price[poolId][scId][assetId] = Price(newPrice, true);
    }

    /// @inheritdoc IValuation
    function getPrice(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (D18) {
        Price memory price_ = price[poolId][scId][assetId];
        require(price_.isValid, "Price not set");

        return price_.value;
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
