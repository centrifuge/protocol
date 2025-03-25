// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

import {JournalEntry, Meta} from "src/common/types/JournalEntry.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

interface IBalanceSheetManager {
    // --- Errors ---
    error EntriesUnbalanced();

    // --- Events ---
    event File(bytes32 indexed what, address data);
    event Permission(PoolId indexed poolId, ShareClassId indexed scId, address contractAddr, bool allowed);
    event Withdraw(
        PoolId indexed poolId,
        ShareClassId indexed scId,
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
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        uint256 timestamp,
        JournalEntry[] debits,
        JournalEntry[] credits
    );
    event Issue(PoolId indexed poolId, ShareClassId indexed scId, address to, uint128 shares);
    event Revoke(PoolId indexed poolId, ShareClassId indexed scId, address from, uint128 shares);
    event UpdateEntry(PoolId indexed poolId, ShareClassId indexed scId, JournalEntry[] debits, JournalEntry[] credits);
    event UpdateValue(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address asset,
        uint256 tokenId,
        D18 pricePerUnit,
        uint256 timestamp
    );

    // Overloaded increase
    function deposit(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address provider,
        uint128 amount,
        D18 pricePerUnit,
        Meta calldata meta
    ) external;

    function withdraw(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint128 amount,
        D18 pricePerUnit,
        bool asAllowance,
        Meta calldata m
    ) external;

    function updateValue(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, D18 pricePerUnit) external;

    function issue(PoolId poolId, ShareClassId scId, address to, uint128 shares, bool asAllowance) external;

    function revoke(PoolId poolId, ShareClassId scId, address from, uint128 shares) external;

    function journalEntry(PoolId poolId, ShareClassId scId, Meta calldata m) external;
}
