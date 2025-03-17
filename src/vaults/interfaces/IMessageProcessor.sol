// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {JournalEntry} from "src/common/types/JournalEntry.sol";

import {D18} from "src/misc/types/D18.sol";

/// @notice Interface for dispatch-only gateway
interface IMessageProcessor {
    /// @notice Creates and send the message
    function sendTransferShares(uint32 chainId, uint64 poolId, bytes16 scId, bytes32 recipient, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId, uint128 amount)
        external;

    /// @notice Creates and send the message
    function sendCancelDepositRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external;

    /// @notice Creates and send the message
    function sendCancelRedeemRequest(uint64 poolId, bytes16 scId, bytes32 investor, uint128 assetId) external;

    /// @notice Creates and send the message
    function sendIncreaseHolding(
        uint64 poolId,
        bytes16 shareClassId,
        uint128 assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external;

    /// @notice Creates and send the message
    function sendDecreaseHolding(
        uint64 poolId,
        bytes16 shareClassId,
        uint128 assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external;

    /// @notice Creates and send the message
    function sendIssueShares(
        uint64 poolId,
        bytes16 shareClassId,
        address receiver,
        uint128 shares,
        uint256 timestamp,
    ) external;

    /// @notice Creates and send the message
    function sendRevokeShares(
        uint64 poolId,
        bytes16 shareClassId,
        address provider,
        uint128 shares,
        uint256 timestamp,
    ) external;

    function sendJournalEntry(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 timestamp,
        JournalEntry[] calldata debits,
        JournalEntry[] calldata credits
    ) external;
}
