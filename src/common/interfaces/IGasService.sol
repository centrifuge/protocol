// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @dev Max cost. No messages will take more that this
uint128 constant MAX_MESSAGE_COST = 3_000_000;

interface IGasService {
    error InvalidMessageType();

    /// @notice Gas limit for the execution cost of an individual message in a remote chain.
    /// @dev    NOTE: In the future we could want to dispatch:
    ///         - by destination chain (for non-EVM chains)
    ///         - by message type
    ///         - by inspecting the payload checking different subsmessages that alter the endpoint processing
    /// @param centrifugeId Where to the cost is defined
    /// @param message Individual message
    /// @return Estimated cost in WEI units
    function messageGasLimit(uint16 centrifugeId, bytes calldata message) external view returns (uint128);

    /// @notice Gas limit for the execution cost of a batch in a remote chain.
    /// @param centrifugeId Where to the cost is defined
    /// @return Max cost in WEI units
    function maxBatchGasLimit(uint16 centrifugeId) external view returns (uint128);

    function scheduleUpgrade() external view returns (uint128);
    function cancelUpgrade() external view returns (uint128);
    function recoverTokens() external view returns (uint128);
    function registerAsset() external view returns (uint128);
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
    function updateContract() external view returns (uint128);
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
}
