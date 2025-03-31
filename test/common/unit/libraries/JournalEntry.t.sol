// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {JournalEntry, JournalEntryLib} from "src/common/types/JournalEntry.sol";
import {AccountId} from "src/common/types/AccountId.sol";

import "forge-std/Test.sol";

// forgefmt: disable-next-item
uint128 constant AMOUNT =
    15 << 0 |
    14 << 8 |
    13 << 16 |
    12 << 24 |
    11 << 32 |
    10 << 40 |
    9 << 48 |
    8 << 56 |
    7 << 64 |
    6 << 72 |
    5 << 80 |
    4 << 88 |
    3 << 96 |
    2 << 104 |
    1 << 112 |
    0 << 120;

uint32 constant ACCOUNT = 19 << 0 | 18 << 8 | 17 << 16 | 16 << 24;

bytes constant encodedEntry = hex"000102030405060708090A0B0C0D0E0F10111213";

contract TestJournalEntry is Test {
    using JournalEntryLib for *;

    function testEntrySerialization() public pure {
        JournalEntry[] memory entries = new JournalEntry[](1);
        entries[0] = JournalEntry(AMOUNT, AccountId.wrap(ACCOUNT));

        bytes memory encoded = entries.toBytes();

        assertEq(encoded, encodedEntry);

        assertEq(abi.encodePacked(AMOUNT, ACCOUNT), encodedEntry);
    }

    function testEntryDeserialization() public pure {
        JournalEntry[] memory entries = encodedEntry.toJournalEntries(0, 20);

        assertEq(entries[0].amount, AMOUNT);
        assertEq(entries[0].accountId.raw(), ACCOUNT);
    }

    function testIdentity() public pure {
        JournalEntry[] memory a = new JournalEntry[](3);
        a[0] = JournalEntry(1, AccountId.wrap(4));
        a[1] = JournalEntry(2, AccountId.wrap(5));
        a[2] = JournalEntry(3, AccountId.wrap(6));

        JournalEntry[] memory b = a.toBytes().toJournalEntries(0, 3 * 20);

        for (uint256 i; i < a.length; i++) {
            assertEq(a[i].amount, a[i].amount);
            assertEq(a[i].accountId.raw(), a[i].accountId.raw());
        }

        assertEq(a.length, b.length);
    }
}
