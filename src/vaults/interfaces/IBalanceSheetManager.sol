// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

import {JournalEntry} from "src/common/types/JournalEntry.sol";

struct Noted {
    uint128 amount;
    bytes32 encoded;
    bool asAllowance;
    Meta m;
}

/// @dev Easy way to construct a decimal number
function isRawPrice(Noted memory n) pure returns (bool) {
    // TODO: Fix retrieving price from bytes32
    return true;
}

function isValuation(Noted memory n) pure returns (bool) {
    // TODO: Fix retrieving price from bytes32
    return true;
}

function asRawPrice(Noted memory n) pure returns (D18) {
    // TODO: Fix retrieving price from bytes32
    return d18(1);
}

function asValuation(Noted memory n) pure returns (address) {
    // TODO: Fix retrieving valuation from bytes32
    return address(uint160(uint256(0)));
}

function allowance(Noted memory n) pure returns (bool) {
    // TODO: Fix retrieving allowance from bytes32
    return false;
}

using {asValuation, asRawPrice, isRawPrice, isValuation, allowance} for Noted global;

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
        bytes32 valuation,
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
        bytes32 valuation,
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

    function issue(uint64 poolId, bytes16 scId, address to, uint128 shares, bool asAllowance) external;

    function revoke(uint64 poolId, bytes16 scId, address from, uint128 shares) external;

    function journalEntry(uint64 poolId, bytes16 scId, Meta calldata m) external;

    function adaptNotedWithdraw(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address from,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata m
    ) external;

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 scId,
        uint128 assetId,
        address from,
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
