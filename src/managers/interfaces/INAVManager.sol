// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {AccountId} from "../../common/types/AccountId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {IValuation} from "../../common/interfaces/IValuation.sol";
import {ISnapshotHook} from "../../common/interfaces/ISnapshotHook.sol";

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

interface INAVManager is ISnapshotHook {
    event UpdateManager(address indexed manager, bool canManage);
    event SetNavHook(address indexed navHook);
    event InitializeNetwork(uint16 indexed centrifugeId);
    event InitializeHolding(ShareClassId indexed scId, AssetId indexed assetId);
    event InitializeLiability(ShareClassId indexed scId, AssetId indexed assetId);
    event Sync(ShareClassId indexed scId, uint16 indexed centrifugeId, uint128 netAssetValue);
    event Transfer(
        ShareClassId indexed scId_,
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        uint128 sharesTransferred
    );

    error MismatchedEpochs();
    error AlreadyInitialized();
    error NotInitialized();
    error ExceedsMaxAccounts();
    error InvalidNAVHook();
    error InvalidPoolId();
    error EmptyAddress();
    error NotAuthorized();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Get the NAV hook
    function navHook() external view returns (INAVHook);

    /// @notice Set the NAV hook contract that will receive NAV updates
    /// @param navHook The address of the NAV hook contract
    function setNAVHook(INAVHook navHook) external;

    /// @notice Check if an address can call management functions
    function manager(address manager) external view returns (bool);

    /// @notice Update whether an address can call management functions
    /// @param manager The address of the manager
    /// @param canManage Whether the address can call management functions
    function updateManager(address manager, bool canManage) external;

    //----------------------------------------------------------------------------------------------
    // Account creation
    //----------------------------------------------------------------------------------------------

    /// @notice Initialize a new network by creating core accounts (equity, liability, gain, loss)
    /// @param centrifugeId The Centrifuge ID of the network to initialize
    function initializeNetwork(uint16 centrifugeId) external;

    /// @notice Initialize a new holding asset account and associate it with the hub
    /// @param scId The share class ID
    /// @param assetId The asset ID to initialize
    /// @param valuation The valuation contract for this asset
    function initializeHolding(ShareClassId scId, AssetId assetId, IValuation valuation) external;

    /// @notice Initialize a new liability account and associate it with the hub
    /// @param scId The share class ID
    /// @param assetId The asset ID to initialize as a liability
    /// @param valuation The valuation contract for this liability
    function initializeLiability(ShareClassId scId, AssetId assetId, IValuation valuation) external;

    //----------------------------------------------------------------------------------------------
    // Holding updates
    //----------------------------------------------------------------------------------------------

    /// @notice Update the holding value for a specific asset
    /// @param scId The share class ID
    /// @param assetId The asset ID to update
    function updateHoldingValue(ShareClassId scId, AssetId assetId) external;

    /// @notice Update the valuation contract for a specific asset
    /// @param scId The share class ID
    /// @param assetId The asset ID to update
    /// @param valuation The new valuation contract
    function updateHoldingValuation(ShareClassId scId, AssetId assetId, IValuation valuation) external;

    /// @notice Set the account ID for a specific asset holding
    /// @param scId The share class ID
    /// @param assetId The asset ID
    /// @param kind The account kind
    /// @param accountId The account ID to set
    function setHoldingAccountId(ShareClassId scId, AssetId assetId, uint8 kind, AccountId accountId) external;

    /// @notice close gain/loss accounts by moving balances to equity account
    /// @param centrifugeId The Centrifuge ID of the network
    function closeGainLoss(uint16 centrifugeId) external;

    //----------------------------------------------------------------------------------------------
    // Calculations
    //----------------------------------------------------------------------------------------------

    /// @notice Calculate the net asset value for a specific network
    /// @dev NAV = equity + gain - loss - liability
    /// @param centrifugeId The Centrifuge ID of the network
    function netAssetValue(uint16 centrifugeId) external view returns (uint128);

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @notice Get the asset account ID for a specific asset on a network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @param assetId The asset ID
    function assetAccount(uint16 centrifugeId, AssetId assetId) external view returns (AccountId);

    /// @notice Get the expense account ID for a specific asset on a network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @param assetId The asset ID
    function expenseAccount(uint16 centrifugeId, AssetId assetId) external view returns (AccountId);

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
