// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IValuation} from "./IValuation.sol";
import {ISnapshotHook} from "./ISnapshotHook.sol";

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {AccountId} from "../../types/AccountId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

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
    ///         and/or share amounts are in sync between Hub and Spoke
    bool isSnapshot;
    /// @notice The nonce of the snapshot. Incremented after each snapshot is taken.
    uint64 nonce;
}

interface IHoldings {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

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

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

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

    //----------------------------------------------------------------------------------------------
    // Holding creation & updates
    //----------------------------------------------------------------------------------------------

    /// @notice Initializes a new holding in a pool using a valuation
    /// @dev `increase()` and `decrease()` can be called before initialize
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation The valuation contract to use for pricing
    /// @param isLiability Whether this holding represents a liability
    /// @param accounts Array of holding accounts to initialize
    function initialize(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        bool isLiability,
        HoldingAccount[] memory accounts
    ) external;

    /// @notice Increments the amount of a holding and updates the value for that increment
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param pricePoolPerAsset Price in pool currency per asset unit
    /// @param amount Amount to increase by
    /// @return value The value the holding has incremented
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset, uint128 amount)
        external
        returns (uint128 value);

    /// @notice Decrements the amount of a holding and updates the value for that decrement
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param pricePoolPerAsset Price in pool currency per asset unit
    /// @param amount Amount to decrease by
    /// @return value The value the holding has decremented
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, D18 pricePoolPerAsset, uint128 amount)
        external
        returns (uint128 value);

    /// @notice Reset the value of a holding using the current valuation
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return isPositive Indicates whether the diffValue is positive or negative
    /// @return diffValue The difference in value after the new valuation
    function update(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        returns (bool isPositive, uint128 diffValue);

    /// @notice Updates the valuation method used for this holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation The new valuation contract to use
    function updateValuation(PoolId poolId, ShareClassId scId, AssetId assetId, IValuation valuation) external;

    /// @notice Updates whether the holding is a liability
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param isLiability Whether this holding is a liability
    function updateIsLiability(PoolId poolId, ShareClassId scId, AssetId assetId, bool isLiability) external;

    /// @notice Sets an account id for a specific kind
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param kind The account type/kind
    /// @param accountId The account identifier to set
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId)
        external;

    /// @notice Sets the snapshot state for a share class on a specific network
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId The network identifier
    /// @param isSnapshot Whether the state is a snapshot
    /// @param nonce The snapshot nonce for validation
    function setSnapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bool isSnapshot, uint64 nonce)
        external;

    /// @notice Sets the snapshot hook for a pool
    /// @param poolId The pool identifier
    /// @param hook The snapshot hook contract
    function setSnapshotHook(PoolId poolId, ISnapshotHook hook) external;

    /// @notice Checks the snapshot state and calls the hook if it's a snapshot
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId The network identifier
    function callOnSyncSnapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external;

    /// @notice Calls the snapshot hook's onTransfer function if a hook is set
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param originCentrifugeId The origin network identifier
    /// @param targetCentrifugeId The target network identifier
    /// @param amount The amount of shares transferred
    function callOnTransferSnapshot(
        PoolId poolId,
        ShareClassId scId,
        uint16 originCentrifugeId,
        uint16 targetCentrifugeId,
        uint128 amount
    ) external;

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the snapshot hook for the given pool
    /// @param poolId The pool identifier
    /// @return The snapshot hook contract
    function snapshotHook(PoolId poolId) external view returns (ISnapshotHook);

    /// @notice Returns the snapshot info for a given pool, share class and centrifugeId
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId The network identifier
    /// @return isSnapshot Whether the state is a snapshot
    /// @return nonce The current snapshot nonce
    function snapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId)
        external
        view
        returns (bool isSnapshot, uint64 nonce);

    /// @notice Returns the value of this holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return value The current value of the holding
    function value(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 value);

    /// @notice Returns the amount of this holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return amount The current amount of the holding
    function amount(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (uint128 amount);

    /// @notice Returns the valuation method used for this holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return The valuation contract
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IValuation);

    /// @notice Returns if the holding is a liability
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return Whether the holding is a liability
    function isLiability(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool);

    /// @notice Returns an account id for a specific kind
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param kind The account type/kind
    /// @return The account identifier
    function accountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind)
        external
        view
        returns (AccountId);

    /// @notice Tells if the holding was initialized for an asset in a share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return Whether the holding is initialized
    function isInitialized(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool);
}
