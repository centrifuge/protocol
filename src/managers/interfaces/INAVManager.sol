// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISnapshotHook} from "../../common/interfaces/ISnapshotHook.sol";
import {D18} from "../../misc/types/D18.sol";
import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {AccountId} from "../../common/types/AccountId.sol";
import {IValuation} from "../../common/interfaces/IValuation.sol";

interface INAVHook {
    /// @notice Callback when there is a new net asset value (NAV) on a specific network.
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param centrifugeId The Centrifuge ID of the network
    /// @param netAssetValue The new net asset value
    function onUpdate(PoolId poolId, ShareClassId scId, uint16 centrifugeId, D18 netAssetValue) external;

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
    error MismatchedEpochs();
    error AlreadyInitialized();
    error NotInitialized();
    error ExceedsMaxAccounts();
    error InvalidNAVHook();

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Get the NAV hook
    function navHook() external view returns (INAVHook);

    /// @notice Set the NAV hook contract that will receive NAV updates
    /// @param navHook The address of the NAV hook contract
    function setNAVHook(INAVHook navHook) external;

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
    // Price updates
    //----------------------------------------------------------------------------------------------

    /// @notice Update the holding value for a specific asset
    /// @param scId The share class ID
    /// @param assetId The asset ID to update
    function updateHoldingValue(ShareClassId scId, AssetId assetId) external;


    //----------------------------------------------------------------------------------------------
    // Calculations
    //----------------------------------------------------------------------------------------------

    /// @notice Calculate the net asset value for a specific network
    /// @dev NAV = equity + gain - loss - liability
    /// @param centrifugeId The Centrifuge ID of the network
    /// @return The calculated net asset value
    function netAssetValue(uint16 centrifugeId) external view returns (D18);

    //----------------------------------------------------------------------------------------------
    // Helpers
    //----------------------------------------------------------------------------------------------

    /// @notice Get the asset account ID for a specific asset on a network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @param assetId The asset ID
    /// @return The account ID for the asset
    function assetAccount(uint16 centrifugeId, AssetId assetId) external view returns (AccountId);

    /// @notice Get the expense account ID for a specific asset on a network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @param assetId The asset ID
    /// @return The account ID for the expense
    function expenseAccount(uint16 centrifugeId, AssetId assetId) external view returns (AccountId);

    /// @notice Get the equity account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @return The equity account ID
    function equityAccount(uint16 centrifugeId) external pure returns (AccountId);

    /// @notice Get the liability account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @return The liability account ID
    function liabilityAccount(uint16 centrifugeId) external pure returns (AccountId);

    /// @notice Get the gain account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @return The gain account ID
    function gainAccount(uint16 centrifugeId) external pure returns (AccountId);

    /// @notice Get the loss account ID for a specific network
    /// @param centrifugeId The Centrifuge ID of the network
    /// @return The loss account ID
    function lossAccount(uint16 centrifugeId) external pure returns (AccountId);
}
