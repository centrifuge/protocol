// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./INAVManager.sol";

import {D18} from "../../misc/types/D18.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

interface ISimplePriceManager is INAVHook {
    event Update(PoolId indexed poolId, uint128 newNAV, uint128 newIssuance, D18 newSharePrice);
    event Transfer(
        PoolId indexed poolId, uint16 indexed fromCentrifugeId, uint16 indexed toCentrifugeId, uint128 sharesTransferred
    );
    event UpdateManager(PoolId indexed poolId, address indexed manager, bool canManage);

    error InvalidShareClassCount();
    error MismatchedEpochs();

    struct NetworkMetrics {
        uint128 netAssetValue;
        uint128 issuance;
    }

    function globalIssuance(PoolId poolId) external view returns (uint128);
    function globalNetAssetValue(PoolId poolId) external view returns (uint128);
    function metrics(PoolId poolId, uint16 centrifugeId)
        external
        view
        returns (uint128 netAssetValue, uint128 issuance);
    function networks(PoolId poolId, uint256 index) external view returns (uint16);
    function manager(PoolId poolId, address manager_) external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Update the list of networks the pool is active on
    /// @dev Ensure the number of network updates can fit in a single block
    /// @param poolId The pool ID
    /// @param centrifugeIds Array of Centrifuge IDs for networks
    function setNetworks(PoolId poolId, uint16[] calldata centrifugeIds) external;

    /// @notice Update whether an address can manage the NAV manager
    /// @param poolId The pool ID
    /// @param manager The address of the manager
    /// @param canManage Whether the address can manage this manager
    function updateManager(PoolId poolId, address manager, bool canManage) external;

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @notice Approve deposits and issue shares in sequence using current NAV per share
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param depositAssetId The asset ID for deposits
    /// @param approvedAssetAmount Amount of assets to approve
    /// @param extraGasLimit Extra gas limit for cross-chain operations
    function approveDepositsAndIssueShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId depositAssetId,
        uint128 approvedAssetAmount,
        uint128 extraGasLimit
    ) external;

    /// @notice Approve redeems and revoke shares in sequence using current NAV per share
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param payoutAssetId The asset ID for payouts
    /// @param approvedShareAmount Amount of shares to approve for redemption
    /// @param extraGasLimit Extra gas limit for cross-chain operations
    function approveRedeemsAndRevokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint128 approvedShareAmount,
        uint128 extraGasLimit
    ) external;
}
