// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IMessageLimits} from "./IMessageLimits.sol";

/// @dev Max cost. No messages will take more that this
uint128 constant MAX_MESSAGE_COST = 3_100_000;

/// @title  IGasService
/// @notice Interface for estimating gas costs for cross-chain messages
/// @dev    Provides gas cost estimates for each message type in the protocol
interface IGasService is IMessageLimits {
    error InvalidMessageType();

    function scheduleUpgrade() external view returns (uint128);
    function cancelUpgrade() external view returns (uint128);
    function recoverTokens() external view returns (uint128);
    function registerAsset() external view returns (uint128);
    function setPoolAdapters() external view returns (uint128);
    function request() external view returns (uint128);
    function notifyPool() external view returns (uint128);
    function notifyShareClass() external view returns (uint128);
    function notifyPricePoolPerShare() external view returns (uint128);
    function notifyPricePoolPerAsset() external view returns (uint128);
    function notifyShareMetadata() external view returns (uint128);
    function updateShareHook() external view returns (uint128);
    function initiateTransferShares() external view returns (uint128);
    function executeTransferShares() external view returns (uint128);
    function updateRestriction() external view returns (uint128);
    function trustedContractUpdate() external view returns (uint128);
    function requestCallback() external view returns (uint128);
    function updateVaultDeployAndLink() external view returns (uint128);
    function updateVaultLink() external view returns (uint128);
    function updateVaultUnlink() external view returns (uint128);
    function setRequestManager() external view returns (uint128);
    function updateBalanceSheetManager() external view returns (uint128);
    function updateHoldingAmount() external view returns (uint128);
    function updateShares() external view returns (uint128);
    function maxAssetPriceAge() external view returns (uint128);
    function maxSharePriceAge() external view returns (uint128);
    function updateGatewayManager() external view returns (uint128);
    function untrustedContractUpdate() external view returns (uint128);
}
