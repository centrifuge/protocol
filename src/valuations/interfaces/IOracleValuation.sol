// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IValuation} from "../../core/interfaces/IValuation.sol";

interface IOracleValuation is IValuation {
    /// @dev Latest price
    struct Price {
        D18 value;
        /// @dev This is used to separate default (zero) values from valid 0.0 prices
        bool isValid;
    }

    event UpdatePrice(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, D18 newPrice);
    event UpdateFeeder(PoolId indexed poolId, address indexed feeder, bool canFeed);

    error NotFeeder();
    error NotHubManager();
    error PriceNotSet();

    function updateFeeder(PoolId poolId, address feeder_, bool canFeed) external;

    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external;
}
