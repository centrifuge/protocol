// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {AccountId} from "../../common/types/AccountId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {IValuation} from "../../common/interfaces/IValuation.sol";
import {ISnapshotHook} from "../../common/interfaces/ISnapshotHook.sol";

struct Holding {
    uint128 assetAmount;
    uint128 assetAmountValue;
    IValuation valuation; // Used for existence
    bool isLiability;
}

struct HoldingAccount {
    AccountId accountId;
    uint8 kind;
}

struct Snapshot {
    /// @notice Indicates if the current accounting state is a correct snapshot of the balance sheet state, i.e. asset
    /// and/or share amounts are in sync between Hub and Spoke
    bool isSnapshot;
    /// @notice The nonce of the snapshot. Incremented after each snapshot is taken.
    uint64 nonce;
}

interface IHoldings {
    /// @notice Emitted when a holding is initialized
    event Initialize(
        PoolId indexed,
        ShareClassId indexed scId,
        AssetId indexed assetId,
        IValuation valuation,
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
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, bool isPositive, uint128 diffValue
    );

    /// @notice Emitted when a holding valuation is updated
    event UpdateValuation(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, IValuation valuation
    );

    /// @notice Emitted when a holding is updated to a liability, or vice versa
    event UpdateIsLiability(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, bool isLiability
    );

    /// @notice Emitted when an account is for a holding is set
    event SetAccountId(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, uint8 kind, AccountId accountId
    );

    /// @notice Emitted when an snapshot hook for a pool ID is set
    event SetSnapshotHook(PoolId indexed poolId, ISnapshotHook hook);

    /// @notice Emitted when the snapshot state is updated
    event SetSnapshot(
        PoolId indexed poolId, ShareClassId indexed scId, uint16 indexed centrifugeId, bool isSnapshot, uint64 nonce
    );

    /// @notice Item was not found for a required action.
    error HoldingNotFound();

    /// @notice Valuation is not valid.
    error WrongValuation();

    /// @notice ShareClassId is not valid.
    error WrongShareClassId();

    /// @notice AssetId is not valid.
    error WrongAssetId();

    /// @notice Holding was already initialized.
    error AlreadyInitialized();

    error InvalidNonce(uint64 expected, uint64 actual);

    error HoldingNotZero();

    /// @notice Initializes a new holding in a pool using a valuation
    /// @dev    `increase()` and `decrease()` can be called before initialize
    function initialize(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
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
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation) external;

    /// @notice Updates whether the holding is a liability.
    function updateIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability) external;

    /// @notice Sets an account id for an specific kind
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external;

    function setSnapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bool isSnapshot, uint64 nonce)
        external;

    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external;

    /// @notice Returns the value of this holding.
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value);

    /// @notice Returns the amount of this holding.
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount);

    /// @notice Returns the valuation method used for this holding.
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IValuation);

    /// @notice Returns if the holding is a liability
    function isLiability(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool);

    /// @notice Returns an account id for an specific kind
    function accountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind)
        external
        view
        returns (AccountId);

    /// @notice Tells if the holding was initialized for an asset in a share class
    function isInitialized(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool);
}
