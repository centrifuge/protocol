// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {AccountId} from "../../../core/types/AccountId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IHoldings} from "../../../core/hub/interfaces/IHoldings.sol";
import {IValuation} from "../../../core/hub/interfaces/IValuation.sol";
import {IAccounting} from "../../../core/hub/interfaces/IAccounting.sol";
import {ISnapshotHook} from "../../../core/hub/interfaces/ISnapshotHook.sol";
import {IManagerCallFromHub, IManagerCallFromSpoke} from "../../../core/utils/interfaces/IManagerCall.sol";

/// @dev NAVManager's own accounting taxonomy, used only to derive distinct {AccountId}s per role.
///      Distinct from the core {AccountKind} settlement slots, which these accounts are mapped to.
///      The ordinals are load-bearing: they seed on-chain AccountId derivation, so reordering or
///      inserting values would silently repoint existing pools' accounts. Append only.
enum NAVAccount {
    Asset,
    Equity,
    Loss,
    Gain,
    Expense,
    Liability
}

/// @title  INAVHook
/// @notice Interface for receiving net asset value (NAV) update callbacks
interface INAVHook {
    /// @notice Callback when there is a new net asset value (NAV) on a specific network.
    /// @dev    A network's slice of the aggregate only advances on its own sync, so a network whose sync is being
    ///         skipped ({INAVManager} holds it while the pool-network is in deficit) keeps contributing its last
    ///         consistent slice, and a sync from any other network still republishes the price. Its NAV and
    ///         issuance are frozen together, so the aggregate stays coherent, but it is stale in that network's
    ///         share of it.
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param centrifugeId The Centrifuge ID of the network
    /// @param netAssetValue The new net asset value
    function onUpdate(PoolId poolId, ShareClassId scId, uint16 centrifugeId, uint128 netAssetValue) external;

    /// @notice Handle transfer shares between networks
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param fromCentrifugeId The source network Centrifuge ID
    /// @param toCentrifugeId The destination network Centrifuge ID
    /// @param sharesTransferred The amount of shares transferred
    function onTransfer(
        PoolId poolId,
        ShareClassId scId,
        uint16 fromCentrifugeId,
        uint16 toCentrifugeId,
        uint128 sharesTransferred
    ) external;
}

/// @title  INAVManager
/// @notice Manager for multi-network net asset value (NAV) accounting and price calculations
/// @dev    Tracks NAV across multiple networks using double-entry accounting accounts
interface INAVManager is ISnapshotHook, IManagerCallFromHub, IManagerCallFromSpoke {
    /// @notice Discriminator encoded as the first field of the `fromHub` payload; selects the action.
    enum ManagerCall {
        SetNavHook,
        InitializeNetwork,
        InitializeHolding,
        InitializeLiability,
        UpdateHoldingValuation,
        CloseGainLoss,
        UpdateManager,
        SetDefaultValuation,
        SetAccountMetadata
    }

    event SetNavHook(PoolId indexed poolId, address indexed navHook);
    event SetDefaultValuation(PoolId indexed poolId, IValuation indexed valuation);
    event UpdateManager(PoolId indexed poolId, uint16 indexed centrifugeId, bytes32 indexed who, bool canManage);
    event InitializeNetwork(PoolId indexed poolId, uint16 indexed centrifugeId);
    event InitializeHolding(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId);
    event InitializeLiability(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId);
    event SetAccountMetadata(PoolId indexed poolId, AccountId indexed account, bytes metadata);
    event Sync(PoolId indexed poolId, ShareClassId indexed scId, uint16 indexed centrifugeId, uint128 netAssetValue);
    event SkipSync(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        uint16 indexed centrifugeId,
        uint32 deficitCount,
        uint32 networkDeficitCount
    );
    event Transfer(
        PoolId indexed poolId,
        ShareClassId scId,
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        uint128 sharesTransferred
    );

    error NotAuthorized();
    error NotEnvoy();
    error UnexpectedValue();
    error AlreadyInitialized();
    error NotInitialized();
    error InvalidStateOfAccounts();
    error InvalidNAVHook();
    error UnsupportedSpokeCall();
    error NetworkMismatch();
    error NotManager();
    error ValuationNotSet();
    error NotDebitNormalAccount();

    //----------------------------------------------------------------------------------------------
    // Immutables
    //----------------------------------------------------------------------------------------------

    /// @notice Central coordination contract for pool management and cross-chain operations
    function hub() external view returns (IHub);

    /// @notice Tracks asset positions and valuations across all pools and share classes
    function holdings() external view returns (IHoldings);

    /// @notice Double-entry accounting system for recording pool debits and credits
    function accounting() external view returns (IAccounting);

    /// @notice The Envoy, the only authorized caller of `fromHub`
    function envoy() external view returns (address);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Check if a network has been initialized for a pool
    /// @param poolId The pool ID
    /// @param centrifugeId The Centrifuge ID of the network
    function initialized(PoolId poolId, uint16 centrifugeId) external view returns (bool);

    /// @notice Get the NAV hook
    /// @param poolId The pool ID
    function navHook(PoolId poolId) external view returns (INAVHook);

    /// @notice Get the default valuation applied to every holding and liability initialized on a pool
    /// @dev    Required setup step: must be set via the `SetDefaultValuation` manager call before any
    ///         `InitializeHolding` or `InitializeLiability`, which revert with `ValuationNotSet` otherwise.
    /// @param poolId The pool ID
    function defaultValuation(PoolId poolId) external view returns (IValuation);

    /// @notice Check whether an address may drive spoke-side holding/liability initialization for a pool
    ///         on a network, via the permissionless `spoke.managerCall` -> `fromSpoke` path
    /// @param poolId The pool ID
    /// @notice Check whether an address may drive spoke-side holding/liability initialization for a pool
    ///         via the permissionless `spoke.managerCall` -> `fromSpoke` path
    /// @param poolId The pool ID
    /// @param centrifugeId The network the manager calls from; it may only initialize assets residing there,
    ///        cross-network initialization is hub-only
    /// @param who The manager address, encoded as bytes32
    function manager(PoolId poolId, uint16 centrifugeId, bytes32 who) external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Holding updates
    //----------------------------------------------------------------------------------------------

    /// @notice Update the holding value for a specific asset
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param assetId The asset ID to update
    function updateHoldingValue(PoolId poolId, ShareClassId scId, AssetId assetId) external;

    //----------------------------------------------------------------------------------------------
    // Calculations
    //----------------------------------------------------------------------------------------------

    /// @notice Calculate the net asset value for a specific network
    /// @dev NAV = equity + gain - loss - liability
    /// @param poolId The pool ID
    /// @param centrifugeId The Centrifuge ID of the network
    function netAssetValue(PoolId poolId, uint16 centrifugeId) external view returns (uint128);

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @notice Get the asset account ID for a specific asset on a network
    /// @param assetId The asset ID
    function assetAccount(AssetId assetId) external view returns (AccountId);

    /// @notice Get the expense account ID for a specific asset on a network
    /// @param assetId The asset ID
    function expenseAccount(AssetId assetId) external view returns (AccountId);

    /// @notice Get the equity account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    function equityAccount(uint16 centrifugeId) external pure returns (AccountId);

    /// @notice Get the liability account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    function liabilityAccount(uint16 centrifugeId) external pure returns (AccountId);

    /// @notice Get the gain account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    function gainAccount(uint16 centrifugeId) external pure returns (AccountId);

    /// @notice Get the loss account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    function lossAccount(uint16 centrifugeId) external pure returns (AccountId);
}
