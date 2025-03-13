// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {JournalEntry} from "src/common/types/JournalEntry.sol";

struct Noted {
    uint256 amount;
    uint256 pricePerUnit;
    JournalEntry[] debits;
    JournalEntry[] credits;
}

interface IBalanceSheetManager {
    // --- Errors ---

    // --- Events ---
    event File(bytes32 indexed what, address data);
    event Permission(uint64 indexed poolId, bytes16 indexed shareClassId, address contractAddr, bool allowed);
    event NoteWithdraw(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        JournalEntry[] debits,
        JournalEntry[] credits
    );
    event NoteDeposit(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        JournalEntry[] debits,
        JournalEntry[] credits
    );

    // Overloaded increase
    function deposit(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external;

    function deposit(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId, // Replace with correct type if needed
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external;

    function withdraw(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external;

    function withdraw(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId, // Replace with correct type if needed
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external;

    function issue(
        uint64 poolId,
        bytes16 shareClassId,
        address to,
        uint256 shares,
        uint256 pricePerShare,
        uint64 timestamp
    ) external;

    function revoke(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 shares,
        uint256 pricePerShare,
        uint64 timestamp
    ) external;

    function journalEntry(
        uint64 poolId,
        bytes16 shareClassId,
        uint64 timestamp,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external;

    function adaptNotedWithdraw(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external;

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        JournalEntry[] memory debits,
        JournalEntry[] memory credits
    ) external;

    // Overloaded executeNotedWithdraw
    function executeNotedWithdraw(uint64 poolId, bytes16 shareClassId, address asset, uint256 tokenId, address receiver)
        external;

    function executeNotedWithdraw(uint64 poolId, bytes16 shareClassId, uint256 assetId, address receiver) external;

    // Overloaded executeNotedDeposit
    function executeNotedDeposit(uint64 poolId, bytes16 shareClassId, address asset, uint256 tokenId, address receiver)
        external;

    function executeNotedDeposit(uint64 poolId, bytes16 shareClassId, uint256 assetId, address receiver) external;
}
