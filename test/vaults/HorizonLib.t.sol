// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BucketLib} from "../../src/vaults/libraries/BucketLib.sol";
import {HorizonLib} from "../../src/vaults/libraries/HorizonLib.sol";
import {InvestmentState} from "../../src/vaults/interfaces/IAsyncVault.sol";

import "forge-std/Test.sol";

/// @notice The horizon's packed storage against a plain array, over horizons spanning several overflow slots.
contract HorizonLibTest is Test {
    using BucketLib for BucketLib.State;
    using HorizonLib for HorizonLib.State;

    uint128 constant AMOUNT = 100;
    address constant CONTROLLER = address(0xC0FFEE);

    BucketLib.State internal s;
    HorizonLib.State internal h;
    InvestmentState internal ledger;

    uint96 internal lastId;
    uint96[] internal expected;
    mapping(uint96 => bool) internal spent;

    function testFuzzTheHorizonMatchesAnArray(uint256 seed, uint8 limitSeed, uint8 giftSeed) public {
        uint256 limit = bound(limitSeed, 1, 14);
        uint256 giftLimit = bound(giftSeed, 1, limit);

        for (uint256 step; step < 60; step++) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 6;
            uint256 pick = expected.length == 0 ? 0 : (r >> 8) % expected.length;

            if (op <= 1) {
                _add(op == 0, op == 0 ? limit : giftLimit);
            } else if (op == 2 && expected.length > 0) {
                _remove(pick);
            } else if (op == 3 && expected.length > 0) {
                _settle(expected[pick]);
            } else if (op == 4) {
                _fold();
            } else if (op == 5 && expected.length > 0) {
                h.add(s, ledger, CONTROLLER, expected[pick], true, r % 2 == 0, limit);
            }

            _assertMatches();
        }
    }

    function _add(bool own, uint256 limit) internal {
        uint96 id = ++lastId;
        s.contribute(id, CONTROLLER, true, AMOUNT, false, 0);
        s.flush(id);
        h.add(s, ledger, CONTROLLER, id, true, own, limit);

        if (!own && expected.length >= limit) return;
        while (expected.length >= limit) {
            _removeExpected(0);
        }
        expected.push(id);
    }

    function _remove(uint256 index) internal {
        h.remove(s, CONTROLLER, expected[index], true);
        _removeExpected(index);
    }

    function _settle(uint96 id) internal {
        if (spent[id]) return;
        s.settle(id, true, AMOUNT, AMOUNT, 0, 0);
        spent[id] = true;
    }

    function _fold() internal {
        h.fold(s, ledger, CONTROLLER);
        for (uint256 i = expected.length; i > 0; i--) {
            if (spent[expected[i - 1]]) _removeExpected(i - 1);
        }
    }

    function _removeExpected(uint256 index) internal {
        for (uint256 i = index; i + 1 < expected.length; i++) {
            expected[i] = expected[i + 1];
        }
        expected.pop();
    }

    function _assertMatches() internal view {
        uint96[] memory entries = h.entries(s, CONTROLLER, true);
        assertEq(entries.length, expected.length, "length");
        for (uint256 i; i < entries.length; i++) {
            assertEq(entries[i], expected[i], "entry");
        }

        // No overflow slot past the last one in use keeps a stale entry, which `entries` would read as more
        uint256 slotsUsed = expected.length > 2 ? (expected.length + 1) / 4 : 0;
        for (uint256 j = slotsUsed; j < slotsUsed + 4; j++) {
            assertEq(h.more[CONTROLLER][true][j], 0, "stale overflow slot");
        }

        // Every contribution still standing, in the horizon or evicted, counts as pending until a fold completes it
        uint256 standing;
        for (uint96 id = 1; id <= lastId; id++) {
            if (s.contributions[id][CONTROLLER].amount != 0) standing++;
        }
        assertEq(s.sides[CONTROLLER][true].pending, standing * AMOUNT, "pending");
    }
}
