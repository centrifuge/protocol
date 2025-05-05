// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {D18} from "src/misc/types/D18.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

struct Holding {
    uint128 assetAmount;
    uint128 assetAmountValue;
    IERC7726 valuation; // Used for existence
    bool isLiability;
}

struct HoldingAccount {
    AccountId accountId;
    uint8 kind;
}

interface IHoldings {
    /// @notice Emitted when a holding is created
    event Create(
        PoolId indexed,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        IERC7726 valuation,
        bool isLiability,
        HoldingAccount[] accounts
    );

    /// @notice Emitted when a holding is increased
    event Increase(
        PoolId indexed,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        D18 pricePoolPerAsset,
        uint128 amount,
        uint128 increasedValue
    );

    /// @notice Emitted when a holding is decreased
    event Decrease(
        PoolId indexed,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        D18 pricePoolPerAsset,
        uint128 amount,
        uint128 decreasedValue
    );

    /// @notice Emitted when the holding is updated
    event Update(
        PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, bool isPositive, uint128 diffValue
    );

    /// @notice Emitted when a holding valuation is updated
    event UpdateValuation(PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, IERC7726 valuation);

    /// @notice Emitted when an account is for a holding is set
    event SetAccountId(
        PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, uint8 kind, AccountId accountId
    );

    /// @notice Item was not found for a required action
    error HoldingNotFound();

    /// @notice Valuation is not valid.
    error WrongValuation();

    /// @notice ShareClassId is not valid.
    error WrongShareClassId();

    /// @notice AssetId is not valid.
    error WrongAssetId();

    /// @notice Creates a new holding in a pool using a valuation
    function create(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IERC7726 valuation,
        bool isLiability,
        HoldingAccount[] memory accounts
    ) external;

    /// @notice Increments the amount of a holding and updates the value for that increment.
    /// @return value The value the holding has increment.
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset, uint128 amount)
        external
        returns (uint128 value);

    /// @notice Decrements the amount of a holding and updates the value for that decrement.
    /// @return value The value the holding has decrement.
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset, uint128 amount)
        external
        returns (uint128 value);

    /// @notice Reset the value of a holding using the current valuation.
    /// @return isPositive Indicates whether the diffValue is positive or negative
    /// @return diffValue The difference in value after the new valuation.
    function update(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        returns (bool isPositive, uint128 diffValue);

    /// @notice Updates the valuation method used for this holding.
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IERC7726 valuation) external;

    /// @notice Sets an account id for an specific kind
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external;

    /// @notice Returns the value of this holding.
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value);

    /// @notice Returns the amount of this holding.
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount);

    /// @notice Returns the valuation method used for this holding.
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IERC7726);

    /// @notice Returns if the holding is a liability
    function isLiability(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool);

    /// @notice Returns an account id for an specific kind
    function accountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind)
        external
        view
        returns (AccountId);

    /// @notice Tells if the holding exists for an asset in a share class
    function exists(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool);
}
