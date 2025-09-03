// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {IValuation} from "../../common/interfaces/IValuation.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface IOracleValuation is IValuation {
    /// @dev Latest price
    struct Price {
        D18 value;
        /// @dev This is used to separate default (zero) values from valid 0.0 prices
        bool isValid;
    }

    event UpdatePrice(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, D18 newPrice);

    error NotFeeder();
    error NotHubManager();
    error PriceNotSet();

    function updateFeeder(PoolId poolId, address feeder_, bool canFeed) external;
    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external;
}
