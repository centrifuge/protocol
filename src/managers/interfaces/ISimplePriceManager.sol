// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "../../misc/types/D18.sol";
import {PoolId} from "../../common/types/PoolId.sol";
import {AssetId} from "../../common/types/AssetId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";
import {INAVHook} from "./INAVManager.sol";

interface ISimplePriceManager is INAVHook {
    event Update(uint128 newNAV, uint128 newIssuance, D18 newSharePrice);
    event Transfer(uint16 indexed fromCentrifugeId, uint16 indexed toCentrifugeId, uint128 sharesTransferred);
    event UpdateManager(address indexed manager, bool canManage);
    event UpdateCaller(address indexed caller, bool canCall);

    error InvalidShareClassCount();
    error InvalidPoolId();
    error InvalidShareClassId();
    error MismatchedEpochs();
    error EmptyAddress();
    error NotAuthorized();

    struct NetworkMetrics {
        uint128 netAssetValue;
        uint128 issuance;
    }

    function globalIssuance() external view returns (uint128);
    function globalNetAssetValue() external view returns (uint128);
    function metrics(uint16 centrifugeId) external view returns (uint128 netAssetValue, uint128 issuance);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Update the list of networks the pool is active on
    /// @dev Ensure the number of network updates can fit in a single block
    function setNetworks(uint16[] calldata centrifugeIds) external;

    /// @notice Check if an address can manage the NAV manager
    function manager(address manager) external view returns (bool);

    /// @notice Update whether an address can manage the NAV manager
    /// @param manager The address of the manager
    /// @param canManage Whether the address can manage this manager
    function updateManager(address manager, bool canManage) external;

    /// @notice Update whether an address can call NAVHook methods
    /// @param caller The address of the caller
    /// @param canCall Whether the address can call NAVHook methods
    function updateCaller(address caller, bool canCall) external;

    //----------------------------------------------------------------------------------------------
    // Manager actions
    //----------------------------------------------------------------------------------------------

    /// @notice Approve deposits and issue shares in sequence using current NAV per share
    /// @param depositAssetId The asset ID for deposits
    /// @param approvedAssetAmount Amount of assets to approve
    /// @param extraGasLimit Extra gas limit for cross-chain operations
    function approveDepositsAndIssueShares(AssetId depositAssetId, uint128 approvedAssetAmount, uint128 extraGasLimit)
        external;

    /// @notice Approve redeems and revoke shares in sequence using current NAV per share
    /// @param payoutAssetId The asset ID for payouts
    /// @param approvedShareAmount Amount of shares to approve for redemption
    /// @param extraGasLimit Extra gas limit for cross-chain operations
    function approveRedeemsAndRevokeShares(AssetId payoutAssetId, uint128 approvedShareAmount, uint128 extraGasLimit)
        external;
}
