// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IValuation} from "./IValuation.sol";
import {IHubRegistry} from "./IHubRegistry.sol";
import {ISnapshotHook} from "./ISnapshotHook.sol";

import {PoolId} from "../../types/PoolId.sol";
import {AssetId} from "../../types/AssetId.sol";
import {AccountId} from "../../types/AccountId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

struct Holding {
    /// @dev Cumulative amounts, like a token's mint/burn totals. The current amount is derived as
    ///      `increasedAmount - decreasedAmount`, saturating at zero. Tracking both (rather than a single
    ///      clamped balance) lets an over-decrease from rounding net against later increases instead of
    ///      being silently lost, so the hub amount stays reconciled with the spoke's cumulative net.
    uint128 increasedAmount;
    uint128 decreasedAmount;
    uint128 assetAmountValue;
    IValuation valuation; // Used for existence
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
        PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, IValuation valuation, AccountId[4] accounts
    );

    /// @notice Emitted when a holding is increased
    event Increase(
        PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, uint128 amount, uint128 increasedValue
    );

    /// @notice Emitted when a holding is decreased
    event Decrease(
        PoolId indexed, ShareClassId indexed scId, AssetId indexed assetId, uint128 amount, uint128 decreasedValue
    );

    /// @notice Emitted when the deficit counts change, carrying both the share class-network count and the
    ///         pool-network rollup that snapshot hooks gate on
    event UpdateDeficitCount(
        PoolId indexed poolId, ShareClassId indexed scId, uint16 indexed centrifugeId, uint32 count, uint32 networkCount
    );

    /// @notice Emitted when the holding is updated
    event Update(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, bool isPositive, uint128 diffValue
    );

    /// @notice Emitted when a holding valuation is updated
    event UpdateValuation(
        PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId, IValuation valuation
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

    /// @notice Dispatched when the pool does not exist.
    error NonExistingPool();

    /// @notice Valuation is not valid.
    error WrongValuation();

    /// @notice ShareClassId is not valid.
    error WrongShareClassId();

    /// @notice AssetId is not valid.
    error WrongAssetId();

    /// @notice Holding was already initialized.
    error AlreadyInitialized();

    error InvalidNonce(uint64 expected, uint64 actual);

    //----------------------------------------------------------------------------------------------
    // Holding creation & updates
    //----------------------------------------------------------------------------------------------

    /// @notice Initializes a new holding in a pool using a valuation
    /// @dev `increase()` and `decrease()` can be called before initialize
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param valuation The valuation contract to use for pricing
    /// @param accounts Array of holding accounts to initialize
    function initialize(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        IValuation valuation,
        AccountId[4] memory accounts
    ) external;

    /// @notice Increments the amount of a holding and updates the value for that increment
    /// @dev    The realized increment is valued at the hub-side valuation. Before initialization only the
    ///         amount is tracked (value 0); the value is established when the holding is initialized.
    ///         An oracle-backed valuation that reverts on an unset price will stall this call until
    ///         a price is set.
    ///         An increment first nets off any excess carried by a prior over-decrease (see `decrease`):
    ///         only the amount above that excess is realized and valued, so an over-decrease can never be
    ///         re-inflated into overstated value. Lifting a holding out of deficit decrements `deficitCount`.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param centrifugeId The network this increase is reported for, bucketing the deficit counts
    /// @param amount Amount to increase by
    /// @return value The value the holding has incremented
    function increase(PoolId poolId, ShareClassId scId, AssetId assetId, uint16 centrifugeId, uint128 amount)
        external
        returns (uint128 value);

    /// @notice Decrements the amount of a holding and updates the value for that decrement
    /// @dev    A decrease beyond the current amount is not clamped away: it accrues against `decreasedAmount`
    ///         and nets off future increases, so the amount side never reverts on an over-decrease (which
    ///         would stall the ordered message stream) yet never permanently loses the excess.
    ///         The realized decrease removes carrying value pro rata to the realized amount relative to the
    ///         current holding: no valuation call is made, so a stale or unset oracle never stalls a decrease.
    ///         The removed value is capped at the currently stored carrying value so the returned value can
    ///         never over-journal the accounts.
    ///         Pushing a holding into deficit increments `deficitCount`.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param centrifugeId The network this decrease is reported for, bucketing the deficit counts
    /// @param amount Amount to decrease by
    /// @return value The value the holding has decremented
    function decrease(PoolId poolId, ShareClassId scId, AssetId assetId, uint16 centrifugeId, uint128 amount)
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

    /// @notice Sets an account id for a specific kind
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param kind The account type/kind
    /// @param accountId The account identifier to set
    function setAccountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId) external;

    /// @notice Sets the snapshot state for a share class on a specific network
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId The network identifier
    /// @param isSnapshot Whether the state is a snapshot
    /// @param nonce The snapshot nonce for validation
    function setSnapshot(PoolId poolId, ShareClassId scId, uint16 centrifugeId, bool isSnapshot, uint64 nonce) external;

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

    /// @notice Returns the raw cumulative counters of this holding, before the derived amount saturates at zero
    /// @dev    A holding is in deficit when `decreasedAmount > increasedAmount`; `amount()` then saturates at
    ///         zero, so these raw counters are the only way to see the shortfall.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return increasedAmount The cumulative amount ever increased
    /// @return decreasedAmount The cumulative amount ever decreased
    function holdingAmounts(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 increasedAmount, uint128 decreasedAmount);

    /// @notice Returns the number of holdings currently in deficit on a share class-network
    /// @dev    Non-zero means at least one holding of this share class has its amount saturated at zero. Reporting
    ///         only: it names the share class whose holdings are misstated. Gating reads {networkDeficitCount},
    ///         since the NAV a snapshot hook publishes is pooled across a network's share classes.
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param centrifugeId The network identifier
    /// @return count The number of holdings in deficit
    function deficitCount(PoolId poolId, ShareClassId scId, uint16 centrifugeId) external view returns (uint32 count);

    /// @notice Returns the number of holdings currently in deficit on a pool-network, across all its share classes
    /// @dev    Non-zero means at least one holding's amount is saturated at zero, misstating the pool-network NAV.
    ///         Snapshot hooks skip this pool-network entirely while this is non-zero, which holds its NAV slice out
    ///         of the hook rather than holding the pool's published price: a hook aggregating several networks still
    ///         publishes on a sync from any of the others. The rollup rather than {deficitCount} is what gates,
    ///         because a hook's NAV reads accounts shared by every share class on the network, so a deficit under
    ///         one share class misstates what a sync on any other one would publish.
    /// @param poolId The pool identifier
    /// @param centrifugeId The network identifier
    /// @return count The number of holdings in deficit
    function networkDeficitCount(PoolId poolId, uint16 centrifugeId) external view returns (uint32 count);

    /// @notice Returns the valuation method used for this holding
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return The valuation contract
    function valuation(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (IValuation);

    /// @notice Returns an account id for a specific kind
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @param kind The account type/kind
    /// @return The account identifier
    function accountId(PoolId poolId, ShareClassId scId, AssetId assetId, uint8 kind) external view returns (AccountId);

    /// @notice Tells if the holding was initialized for an asset in a share class
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return Whether the holding is initialized
    function isInitialized(PoolId poolId, ShareClassId scId, AssetId assetId) external view returns (bool);

    /// @notice Registry of pools, assets, and manager permissions on the hub chain
    function hubRegistry() external view returns (IHubRegistry);

    /// @notice Returns the holding data for a given pool, share class and asset
    /// @param poolId The pool identifier
    /// @param scId The share class identifier
    /// @param assetId The asset identifier
    /// @return assetAmount The current amount of assets held (derived: increases net of decreases, floored at zero)
    /// @return assetAmountValue The value of assets held in pool currency
    /// @return valuation The valuation contract used for pricing
    function holding(PoolId poolId, ShareClassId scId, AssetId assetId)
        external
        view
        returns (uint128 assetAmount, uint128 assetAmountValue, IValuation valuation);
}
