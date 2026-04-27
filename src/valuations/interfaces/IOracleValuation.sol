// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IValuation} from "../../core/hub/interfaces/IValuation.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";

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
    event UpdateFeeder(PoolId indexed poolId, uint16 indexed centrifugeId, bytes32 indexed feeder, bool canFeed);

    error NotAuthorized();
    error NotFeeder();
    error NotHubManager();
    error PriceNotSet();

    //----------------------------------------------------------------------------------------------
    // State variable getters
    //----------------------------------------------------------------------------------------------

    /// @notice Central coordination contract for pool management and cross-chain operations
    function hub() external view returns (IHub);

    /// @notice Registry of pools, assets, and manager permissions on the hub chain
    function hubRegistry() external view returns (IHubRegistry);

    /// @notice Whether a feeder identifier is authorized to submit price updates for a pool from a given chain
    /// @param poolId The pool identifier
    /// @param centrifugeId The source chain ID (0 for local feeders)
    /// @param feeder_ The identifier of the feeder (bytes32 — supports cross-chain feeders)
    function feeder(PoolId poolId, uint16 centrifugeId, bytes32 feeder_) external view returns (bool);

    /// @notice Latest oracle-supplied price for an asset within a pool's share class
    function pricePoolPerAsset(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (D18 value, bool isValid);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Update the permission for a feeder to set prices for a pool
    /// @param poolId The pool identifier
    /// @param centrifugeId The source chain ID (0 for local feeders)
    /// @param feeder_ The identifier of the feeder
    /// @param canFeed Whether the feeder can set prices
    function updateFeeder(PoolId poolId, uint16 centrifugeId, bytes32 feeder_, bool canFeed) external;

    /// @notice Set the price for an asset in a pool's share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param newPrice The new price value
    function setPrice(PoolId poolId, ShareClassId scId, AssetId assetId, D18 newPrice) external;
}
