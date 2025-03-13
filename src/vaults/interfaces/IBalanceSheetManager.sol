// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

struct Entry {
    uint256 amount;
    uint32 accountId;
}

struct Noted {
    uint256 amount;
    uint256 pricePerUnit;
    Entry[] debits;
    Entry[] credits;
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
        Entry[] debits,
        Entry[] credits
    );
    event NoteDeposit(
        uint64 indexed poolId,
        bytes16 indexed shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        Entry[] debits,
        Entry[] credits
    );

    // Overloaded increase
    function increase(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external;

    function increase(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId, // Replace with correct type if needed
        address provider,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external;

    function decrease(
        uint64 poolId,
        bytes16 shareClassId,
        address asset,
        uint256 tokenId,
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external;

    function decrease(
        uint64 poolId,
        bytes16 shareClassId,
        uint256 assetId, // Replace with correct type if needed
        address receiver,
        uint256 amount,
        uint256 pricePerUnit,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
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

    function journal(
        uint64 poolId,
        bytes16 shareClassId,
        uint64 timestamp,
        Entry[] memory debits,
        Entry[] memory credits
    ) external;

    function adaptNotedWithdraw(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        Entry[] memory debits,
        Entry[] memory credits
    ) external;

    function adaptNotedDeposit(
        uint64 poolId,
        bytes16 shareClassId,
        address from,
        uint256 assetId,
        uint256 amount,
        uint256 pricePerUnit,
        Entry[] memory debits,
        Entry[] memory credits
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
