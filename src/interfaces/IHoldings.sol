// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {AccountId} from "src/types/AccountId.sol";
import {ShareClassId} from "src/types/ShareClassId.sol";
import {IERC7726} from "src/interfaces/IERC7726.sol";

interface IHoldings {
    /// @notice Emitted when a call to `file()` was performed.
    event File(bytes32 indexed what, address addr);

    /// @notice Emitted when a holding is created
    event Created(PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, IERC7726 valuation);

    /// @notice Emitted when a holding is increased
    event Increased(
        PoolId indexed,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        IERC7726 valuation,
        uint128 amount,
        uint128 increasedValue
    );

    /// @notice Emitted when a holding is decreased
    event Decreased(
        PoolId indexed,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        IERC7726 valuation,
        uint128 amount,
        uint128 decreasedValue
    );

    /// @notice Emitted when the holding is updated
    event Updated(PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, int128 diffValue);

    /// @notice Emitted when a holding valuation is updated
    event ValuationUpdated(PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, IERC7726 valuation);

    /// @notice Emitted when an account is for a holding is set
    event AccountIdSet(PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, AccountId accountId);

    /// @notice Dispatched when the `what` parameter of `file()` is not supported by the implementation.
    error FileUnrecognizedWhat();

    /// @notice Item was not found for a required action
    error HoldingNotFound();

    /// @notice Valuation is not valid.
    error WrongValuation();

    /// @notice ShareClassId is not valid.
    error WrongShareClassId();

    /// @notice AssetId is not valid.
    error WrongAssetId();

    /// @notice AssetId not allowed.
    error AssetNotAllowed();

    /// @notice Updates a contract parameter.
    /// @param what Name of the parameter to update.
    /// Accepts a `bytes32` representation of 'poolRegistry' string value.
    /// @param data New value given to the `what` parameter
    function file(bytes32 what, address data) external;

    /// @notice Creates a new holding in a pool using a valuation
    function create(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation, AccountId[] memory accounts)
        external;

    /// @notice Increments the amount of a holding and updates the value for that increment.
    /// @return value The value the holding has increment.
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        external
        returns (uint128 value);

    /// @notice Decrements the amount of a holding and updates the value for that decrement.
    /// @return value The value the holding has decrement.
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation, uint128 amount)
        external
        returns (uint128 value);

    /// @notice Reset the value of a holding using the current valuation.
    /// @return diffValue The difference in value after the new valuation.
    function update(PoolId poolId, ShareClassId scId, AssetId assetId) external returns (int128 diffValue);

    /// @notice Updates the valuation method used for this holding.
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation) external;

    /// @notice Sets an account id for an specific kind
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, AccountId accountId) external;

    /// @notice Returns the value of this holding.
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value);

    /// @notice Returns the amount of this holding.
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount);

    /// @notice Returns the valuation method used for this holding.
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IERC7726);

    /// @notice Returns an account id for an specific kind
    function accountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind)
        external
        view
        returns (AccountId);

    /// @notice returns the allowance of an asset as a holding
    function isAssetAllowed(PoolId poolId, AssetId assetId) external returns (bool);
}
