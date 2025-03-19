// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

import {JournalEntry, Meta} from "src/common/types/JournalEntry.sol";

interface IBalanceSheetManager {
    // --- Errors ---

    // --- Events ---
    event File(bytes32 indexed what, address data);
    event Permission(uint64 indexed poolId, bytes16 indexed scId, address contractAddr, bool allowed);
    event Withdraw(
        uint64 indexed poolId,
        bytes16 indexed scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
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
        uint256 timestamp,
        JournalEntry[] debits,
        JournalEntry[] credits
    );
    event IssueShares(uint64 indexed poolId, bytes16 indexed scId, address to, uint128 shares);
    event RevokeShares(uint64 indexed poolId, bytes16 indexed scId, address from, uint128 shares);

    // Overloaded increase
    function deposit(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        address valuation,
        Meta calldata meta
    ) external;

    function withdraw(
        uint64 poolId,
        bytes16 scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        address valuation,
        bool asAllowance,
        Meta calldata m
    ) external;

    function issue(uint64 poolId, bytes16 scId, address to, uint128 shares, bool asAllowance) external;

    function revoke(uint64 poolId, bytes16 scId, address from, uint128 shares) external;

    function journalEntry(uint64 poolId, bytes16 scId, Meta calldata m) external;
}
