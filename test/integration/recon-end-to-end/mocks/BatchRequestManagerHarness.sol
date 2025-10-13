// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BatchRequestManager} from "src/vaults/BatchRequestManager.sol";
import {IHubRegistry} from "src/core/hub/interfaces/IHubRegistry.sol";
import {PoolId} from "src/core/types/PoolId.sol";
import {AssetId} from "src/core/types/AssetId.sol";
import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {RequestCallbackMessageLib} from "src/vaults/libraries/RequestCallbackMessageLib.sol";

/// @title BatchRequestManagerHarness
/// @notice Test harness that overrides notifyDeposit/notifyRedeem to return internal values
/// @dev Used in invariant tests to get exact claimed/cancelled breakdowns without event parsing
contract BatchRequestManagerHarness is BatchRequestManager {
    constructor(IHubRegistry hubRegistry_, address deployer)
        BatchRequestManager(hubRegistry_, deployer) {}

    /// @notice Wrapper around notifyDeposit that returns the calculated amounts
    /// @dev This allows tests to capture exact amounts without parsing events
    /// @return totalPayoutShareAmount Total shares paid out
    /// @return totalPaymentAssetAmount Total assets used for payment
    /// @return cancelledAssetAmount Total assets cancelled
    function notifyDepositWithReturn(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint32 maxClaims,
        address refund
    ) external payable protected returns (
        uint128 totalPayoutShareAmount,
        uint128 totalPaymentAssetAmount,
        uint128 cancelledAssetAmount
    ) {
        // Loop through claims just like the base implementation
        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutShareAmount, uint128 paymentAssetAmount, uint128 cancelled, bool canClaimAgain) =
                _claimDeposit(poolId, scId, investor, assetId);

            totalPayoutShareAmount += payoutShareAmount;
            totalPaymentAssetAmount += paymentAssetAmount;

            // Cancelled amount is written at most once with non-zero amount
            if (cancelled > 0) {
                cancelledAssetAmount = cancelled;
            }

            if (!canClaimAgain) {
                break;
            }
        }

        // Send callback if there were any claims or cancellations
        if (totalPaymentAssetAmount > 0 || cancelledAssetAmount > 0) {
            hub.requestCallback{value: msg.value}(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.serialize(
                    RequestCallbackMessageLib.FulfilledDepositRequest({
                        investor: investor,
                        fulfilledShareAmount: totalPayoutShareAmount,
                        fulfilledAssetAmount: totalPaymentAssetAmount,
                        cancelledAssetAmount: cancelledAssetAmount
                    })
                ),
                0, // extraGasLimit
                refund
            );
        }

        return (totalPayoutShareAmount, totalPaymentAssetAmount, cancelledAssetAmount);
    }

    /// @notice Wrapper around notifyRedeem that returns the calculated amounts
    /// @dev This allows tests to capture exact amounts without parsing events
    /// @return totalPayoutAssetAmount Total assets paid out
    /// @return totalPaymentShareAmount Total shares used for payment
    /// @return cancelledShareAmount Total shares cancelled
    function notifyRedeemWithReturn(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        bytes32 investor,
        uint32 maxClaims,
        address refund
    ) external payable protected returns (
        uint128 totalPayoutAssetAmount,
        uint128 totalPaymentShareAmount,
        uint128 cancelledShareAmount
    ) {
        // Loop through claims just like the base implementation
        for (uint32 i = 0; i < maxClaims; i++) {
            (uint128 payoutAssetAmount, uint128 paymentShareAmount, uint128 cancelled, bool canClaimAgain) =
                _claimRedeem(poolId, scId, investor, assetId);

            totalPayoutAssetAmount += payoutAssetAmount;
            totalPaymentShareAmount += paymentShareAmount;

            // Cancelled amount is written at most once with non-zero amount
            if (cancelled > 0) {
                cancelledShareAmount = cancelled;
            }

            if (!canClaimAgain) {
                break;
            }
        }

        // Send callback if there were any claims or cancellations
        if (totalPaymentShareAmount > 0 || cancelledShareAmount > 0) {
            hub.requestCallback{value: msg.value}(
                poolId,
                scId,
                assetId,
                RequestCallbackMessageLib.serialize(
                    RequestCallbackMessageLib.FulfilledRedeemRequest({
                        investor: investor,
                        fulfilledAssetAmount: totalPayoutAssetAmount,
                        fulfilledShareAmount: totalPaymentShareAmount,
                        cancelledShareAmount: cancelledShareAmount
                    })
                ),
                0, // extraGasLimit
                refund
            );
        }

        return (totalPayoutAssetAmount, totalPaymentShareAmount, cancelledShareAmount);
    }

    /// @notice Exposes internal _claimDeposit for testing
    /// @dev Kept for potential direct testing needs
    function claimDeposit(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId depositAssetId
    ) public returns (
        uint128 payoutShareAmount,
        uint128 paymentAssetAmount,
        uint128 cancelledAssetAmount,
        bool canClaimAgain
    ) {
        return _claimDeposit(poolId, scId, investor, depositAssetId);
    }

    /// @notice Exposes internal _claimRedeem for testing
    /// @dev Kept for potential direct testing needs
    function claimRedeem(
        PoolId poolId,
        ShareClassId scId,
        bytes32 investor,
        AssetId payoutAssetId
    ) public returns (
        uint128 payoutAssetAmount,
        uint128 paymentShareAmount,
        uint128 cancelledShareAmount,
        bool canClaimAgain
    ) {
        return _claimRedeem(poolId, scId, investor, payoutAssetId);
    }
}