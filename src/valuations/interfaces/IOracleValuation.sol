// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IValuation} from "../../core/hub/interfaces/IValuation.sol";

/// @title  IOracleValuation
/// @notice Interface for oracle-based asset price feeds with permissioned feeders
/// @dev    Extends IValuation to provide oracle price updates with feeder access control
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

    /// @notice Update the permission for a feeder to set prices for a pool
    /// @param poolId The pool identifier
    /// @param feeder_ The address of the feeder
    /// @param canFeed Whether the feeder can set prices
    function updateFeeder(PoolId poolId, address feeder_, bool canFeed) external;

    /// @notice Set the price for an asset in a pool's share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param newPrice The new price value
    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external;
}
