// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

/// Interface for valuation of assets, denominated in the pool currency.
interface IValuation {
    /// @notice TODO
    function getPrice(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (D18);

    /// @notice Returns the value of baseAmount of base in quote terms, e.g. 10 ETH (base) in USDC (quote).
    /// @param assetId The asset in which the baseAmount is denominated in
    /// @param baseAmount The amount of base in base terms.
    function getQuote(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 baseAmount)
        external
        view
        returns (uint128 quoteAmount);
}
