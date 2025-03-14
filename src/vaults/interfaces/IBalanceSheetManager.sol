// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18} from "src/misc/types/D18.sol";

import {JournalEntry} from "src/common/types/JournalEntry.sol";

struct Noted {
    uint128 amount;
    D18 pricePerUnit;
    Meta m;
}

struct Meta {
    uint64 timestamp;
    JournalEntry[] debits;
    JournalEntry[] credits;
}

interface IBalanceSheetManager {
    // --- Errors ---

    // --- Events ---
    event File(bytes32 indexed what, address data);
    event Permission(uint64 indexed poolId, bytes16 indexed scId, address contractAddr, bool allowed);
    event NoteWithdraw(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address from,
        address asset,
        uint256 tokenId,
        uint128 amount,
        D18 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] debits,
        JournalEntry[] credits
    );
    event NoteDeposit(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address from,
        address asset,
        uint256 tokenId,
        uint128 amount,
        D18 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] debits,
        JournalEntry[] credits
    );
    event Withdraw(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] debits,
        JournalEntry[] credits
    );
    event Deposit(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        uint64 timestamp,
        JournalEntry[] debits,
        JournalEntry[] credits
    );

    // Overloaded increase
    function deposit(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata meta
    ) external;

    function deposit(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata meta
    ) external;

    function withdraw(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external;

    function withdraw(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external;

    function issue(uint64 poolId, bytes16 scId, address to, uint128 shares, D18 pricePerShare, uint64 timestamp)
        external;

    function revoke(uint64 poolId, bytes16 scId, address from, uint128 shares, D18 pricePerShare, uint64 timestamp)
        external;

    function journalEntry(uint64 poolId, bytes16 scId, Meta calldata m) external;

    function adaptNotedWithdraw(
        uint64 poolId,
        bytes16 scId,
        address from,
        uint128 assetId,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external;

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 scId,
        address from,
        uint128 assetId,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external;

    // Overloaded executeNotedWithdraw
    function executeNotedWithdraw(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address receiver)
        external;

    function executeNotedWithdraw(uint64 poolId, bytes16 scId, uint128 assetId, address receiver) external;

    // Overloaded executeNotedDeposit
    function executeNotedDeposit(uint64 poolId, bytes16 scId, address asset, uint256 tokenId, address receiver)
        external;

    function executeNotedDeposit(uint64 poolId, bytes16 scId, uint128 assetId, address receiver) external;
}
