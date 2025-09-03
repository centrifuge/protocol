// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IIdentityValuation} from "./interfaces/IIdentityValuation.sol";

import {d18} from "../misc/types/D18.sol";
import {IERC6909Decimals} from "../misc/interfaces/IERC6909.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {AssetId} from "../common/types/AssetId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";
import {PricingLib} from "../common/libraries/PricingLib.sol";
import {IValuation} from "../common/interfaces/IValuation.sol";

import {IHubRegistry} from "../hub/interfaces/IHubRegistry.sol";

contract IdentityValuation is IIdentityValuation {
    IHubRegistry public immutable hubRegistry;

    constructor(IHubRegistry hubRegistry_) {
        hubRegistry = hubRegistry_;
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
