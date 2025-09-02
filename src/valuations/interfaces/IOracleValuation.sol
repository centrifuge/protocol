// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IValuation} from "../../common/interfaces/IValuation.sol";

interface IOracleValuation is IValuation {
    struct Price {
        D18 value;
        /// @dev This is used to separate default (zero) values from valid 0.0 prices
        bool isValid;
    }

    event UpdatePrice(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, D18 newPrice);

    error NotFeeder();
    error NotHubManager();
}
