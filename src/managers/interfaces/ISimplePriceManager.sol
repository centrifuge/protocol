// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../misc/types/D18.sol";
import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {INAVHook} from "./INavManager.sol";

interface ISimplePriceManager is INAVHook {
    error InvalidShareClassCount();
    error MismatchedEpochs();

    struct NetworkMetrics {
        D18 netAssetValue;
        uint128 issuance;
    }

    // function poolId() external view returns (PoolId);
    // function scId() external view returns (ShareClassId);
    // function networks(uint256 index) external view returns (uint16);
    // function globalIssuance() external view returns (uint128);
    // function globalNetAssetValue() external view returns (D18);

    function setNetworks(uint16[] calldata centrifugeIds) external;

    /// @notice Approve deposits and issue shares in sequence using current NAV per share
    /// @param depositAssetId The asset ID for deposits
    /// @param approvedAssetAmount Amount of assets to approve
    /// @param extraGasLimit Extra gas limit for cross-chain operations
    function approveDepositsAndIssueShares(
        AssetId depositAssetId,
        uint128 approvedAssetAmount,
        uint128 extraGasLimit
    ) external;

    /// @notice Approve redeems and revoke shares in sequence using current NAV per share
    /// @param payoutAssetId The asset ID for payouts
    /// @param approvedShareAmount Amount of shares to approve for redemption
    /// @param extraGasLimit Extra gas limit for cross-chain operations
    function approveRedeemsAndRevokeShares(
        AssetId payoutAssetId,
        uint128 approvedShareAmount,
        uint128 extraGasLimit
    ) external;
}
