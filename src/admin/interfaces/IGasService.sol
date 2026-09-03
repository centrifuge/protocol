// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageProperties} from "../../core/messaging/interfaces/IMessageProperties.sol";

/// @title  IGasService
/// @notice Interface for estimating gas costs for cross-chain messages
/// @dev    Provides gas cost estimates for each message type in the protocol
interface IGasService is IMessageProperties {
    error InvalidMessageType();

    /// @notice Packed uint8 array of per-chain block gas limits (in millions), indexed by centrifugeId (first 32 chains)
    function txLimitsPerCentrifugeId() external view returns (uint256);

    function scheduleUpgrade() external view returns (uint128);
    function cancelUpgrade() external view returns (uint128);
    function registerAsset() external view returns (uint128);
    function setPoolAdapters() external view returns (uint128);
    function request() external view returns (uint128);
    function notifyPool() external view returns (uint128);
    function notifyShareClass() external view returns (uint128);
    function notifyPricePoolPerShare() external view returns (uint128);
    function notifyPricePoolPerAsset() external view returns (uint128);
    function notifyShareMetadata() external view returns (uint128);
    function initiateTransferShares() external view returns (uint128);
    function executeTransferShares() external view returns (uint128);
    function updateRestriction() external view returns (uint128);
    function managerCallFromHub() external view returns (uint128);
    function requestCallback() external view returns (uint128);
    function updateVaultDeployAndLink() external view returns (uint128);
    function updateVaultLink() external view returns (uint128);
    function updateVaultUnlink() external view returns (uint128);
    function setRequestManager() external view returns (uint128);
    function setPolicy() external view returns (uint128);
    function authorizeSpokeCall() external view returns (uint128);
    function unauthorizeSpokeCall() external view returns (uint128);
    function updateManager() external view returns (uint128);
    function updateAssets() external view returns (uint128);
    function updateShares() external view returns (uint128);
    function managerCallFromSpoke() external view returns (uint128);
}
