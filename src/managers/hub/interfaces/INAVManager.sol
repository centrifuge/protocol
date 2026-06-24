// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {AccountId} from "../../../core/types/AccountId.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IHoldings} from "../../../core/hub/interfaces/IHoldings.sol";
import {IAccounting} from "../../../core/hub/interfaces/IAccounting.sol";
import {ISnapshotHook} from "../../../core/hub/interfaces/ISnapshotHook.sol";
import {IManagerCallFromHub} from "../../../core/utils/interfaces/IManagerCall.sol";

/// @title  INAVHook
/// @notice Interface for receiving net asset value (NAV) update callbacks
interface INAVHook {
    /// @notice Callback when there is a new net asset value (NAV) on a specific network.
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
interface INAVManager is ISnapshotHook, IManagerCallFromHub {
    /// @notice Discriminator encoded as the first field of the `fromHub` payload; selects the action.
    enum ManagerCall {
        SetNavHook,
        InitializeNetwork,
        InitializeHolding,
        InitializeLiability,
        UpdateHoldingValuation,
        CloseGainLoss
    }

    event SetNavHook(PoolId indexed poolId, address indexed navHook);
    event InitializeNetwork(PoolId indexed poolId, uint16 indexed centrifugeId);
    event InitializeHolding(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId);
    event InitializeLiability(PoolId indexed poolId, ShareClassId indexed scId, AssetId indexed assetId);
    event Sync(PoolId indexed poolId, ShareClassId indexed scId, uint16 indexed centrifugeId, uint128 netAssetValue);
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
    error MismatchedEpochs();
    error AlreadyInitialized();
    error NotInitialized();
    error ExceedsMaxAccounts();
    error InvalidStateOfAccounts();
    error InvalidNAVHook();

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
