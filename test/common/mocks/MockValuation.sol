// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {MathLib} from "../../../src/misc/libraries/MathLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {PricingLib} from "../../../src/common/libraries/PricingLib.sol";
import {IValuation} from "../../../src/common/interfaces/IValuation.sol";

import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";

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
    function getQuote(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount)
    {
        Price memory price_ = price[poolId][scId][assetId];
        require(price_.isValid, "Price not set");

        return PricingLib.convertWithPrice(
            baseAmount, hubRegistry.decimals(assetId), hubRegistry.decimals(poolId), price_.value
        );
    }
}
