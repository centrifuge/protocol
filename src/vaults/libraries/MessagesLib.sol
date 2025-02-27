// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BytesLib} from "src/misc/libraries/BytesLib.sol";

/// @title  MessagesLib
/// @dev    Library for encoding and decoding messages.
library MessagesLib {
    using BytesLib for bytes;

    enum Call {
        /// 0 - An invalid message
        Invalid,
        // --- Gateway ---
        /// 1 - Proof
        MessageProof,
        /// 2 - Initiate Message Recovery
        InitiateMessageRecovery,
        /// 3 - Dispute Message Recovery
        DisputeMessageRecovery,
        /// 4 - Batch Messages
        Batch,
        // --- Root ---
        /// 5 - Schedule an upgrade contract to be granted admin rights
        ScheduleUpgrade,
        /// 6 - Cancel a previously scheduled upgrade
        CancelUpgrade,
        /// 7 - Recover tokens sent to the wrong contract
        RecoverTokens,
        // --- Gas service ---
        /// 8 - Update Centrifuge gas price
        UpdateCentrifugeGasPrice,
        // --- Pool Manager ---
        /// 9 - Add an asset id -> EVM address mapping
        AddAsset,
        /// 10 - Add Pool
        AddPool,
        /// 11 - Add a Pool's Tranche Token
        AddTranche,
        /// 12 - Allow an asset to be used as an asset for investing in pools
        AllowAsset,
        /// 13 - Disallow an asset to be used as an asset for investing in pools
        DisallowAsset,
        /// 14 - Update the price of a Tranche Token
        UpdateTranchePrice,
        /// 15 - Update tranche token metadata
        UpdateTrancheMetadata,
        /// 16 - Update Tranche Hook
        UpdateTrancheHook,
        /// 17 - A transfer of assets
        /// REMOVED: TransferAssets,
        /// 18 - A transfer of tranche tokens
        TransferTrancheTokens,
        /// 19 - Update a user restriction
        UpdateRestriction,
        /// --- Investment Manager ---
        /// 20 - Increase an investment order by a given amount
        DepositRequest,
        /// 21 - Increase a Redeem order by a given amount
        RedeemRequest,
        /// 22 - Executed Collect Invest
        FulfilledDepositRequest,
        /// 23 - Executed Collect Redeem
        FulfilledRedeemRequest,
        /// 24 - Cancel an investment order
        CancelDepositRequest,
        /// 25 - Cancel a redeem order
        CancelRedeemRequest,
        /// 26 - Executed Decrease Invest Order
        FulfilledCancelDepositRequest,
        /// 27 - Executed Decrease Redeem Order
        FulfilledCancelRedeemRequest,
        /// 28 - Request redeem investor
        TriggerRedeemRequest
    }

    function messageType(bytes memory _msg) internal pure returns (Call _call) {
        _call = Call(_msg.toUint8(0));
    }
}
