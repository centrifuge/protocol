// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {INAVHook} from "./INAVManager.sol";

import {D18} from "../../../misc/types/D18.sol";

import {PoolId} from "../../../common/types/PoolId.sol";
import {AssetId} from "../../../common/types/AssetId.sol";
import {ShareClassId} from "../../../common/types/ShareClassId.sol";

interface ISimplePriceManager is INAVHook {
    event Update(PoolId indexed poolId, ShareClassId scId, uint128 newNAV, uint128 newIssuance, D18 newSharePrice);
    event Transfer(
        PoolId indexed poolId,
        ShareClassId scId,
        uint16 indexed fromCentrifugeId,
        uint16 indexed toCentrifugeId,
        uint128 sharesTransferred
    );
    event UpdateManager(PoolId indexed poolId, address indexed manager, bool canManage);
    event UpdateNetworks(PoolId indexed poolId, uint16[] networks);
    event File(bytes32 indexed what, address data);

    error InvalidShareClassCount();
    error InvalidShareClass();
    error MismatchedEpochs();
    error FileUnrecognizedParam();
    error NetworkNotFound();

    struct Metrics {
        uint128 netAssetValue;
        uint128 issuance;
        uint16[] networks;
    }

    struct NetworkMetrics {
        uint128 netAssetValue;
        uint128 issuance;
        uint32 issueEpochsBehind;
        uint32 revokeEpochsBehind;
    }

    function metrics(PoolId poolId) external view returns (uint128 netAssetValue, uint128 issuance);
    function networks(PoolId poolId) external view returns (uint16[] memory networks);
    function networkMetrics(PoolId poolId, uint16 centrifugeId)
        external
        view
        returns (uint128 netAssetValue, uint128 issuance, uint32 issueEpochsBehind, uint32 revokeEpochsBehind);
    function manager(PoolId poolId, address manager_) external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Add a network to the pool
    /// @param poolId The pool ID
    /// @param centrifugeId Centrifuge ID for the network to add
    function addNetwork(PoolId poolId, uint16 centrifugeId) external;

    /// @notice Remove a network from the pool
    /// @param poolId The pool ID
    /// @param centrifugeId Centrifuge ID for the network to remove
    function removeNetwork(PoolId poolId, uint16 centrifugeId) external;

    /// @notice Update whether an address can manage the NAV manager
    /// @param poolId The pool ID
    /// @param manager The address of the manager
    /// @param canManage Whether the address can manage this manager
    function updateManager(PoolId poolId, address manager, bool canManage) external;

    function file(bytes32 what, address data) external;

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @notice Approve deposit requests for a given asset amount
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param depositAssetId The asset ID for deposits
    /// @param approvedAssetAmount Amount of assets to approve for deposit
    function approveDeposits(PoolId poolId, ShareClassId scId, AssetId depositAssetId, uint128 approvedAssetAmount)
        external;

    /// @notice Issue shares from approved deposit requests
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param depositAssetId The asset ID for deposits
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
    function issueShares(PoolId poolId, ShareClassId scId, AssetId depositAssetId, uint128 extraGasLimit) external;

    /// @notice Approve redemption requests for a given share amount
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param payoutAssetId The asset ID for payouts
    /// @param approvedShareAmount Amount of shares to approve for redemption
    function approveRedeems(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, uint128 approvedShareAmount)
        external;

    /// @notice Revoke shares from approved redemption requests
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param payoutAssetId The asset ID for payouts
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
    function revokeShares(PoolId poolId, ShareClassId scId, AssetId payoutAssetId, uint128 extraGasLimit) external;

    /// @notice Approve deposits and issue shares in sequence using current NAV per share
    /// @param poolId The pool ID
    /// @param scId The share class ID
    /// @param depositAssetId The asset ID for deposits
    /// @param approvedAssetAmount Amount of assets to approve
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
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
    /// @param extraGasLimit Extra gas limit for some computation that may need to happen on the remote chain
    function approveRedeemsAndRevokeShares(
        PoolId poolId,
        ShareClassId scId,
        AssetId payoutAssetId,
        uint128 approvedShareAmount,
        uint128 extraGasLimit
    ) external;
}
