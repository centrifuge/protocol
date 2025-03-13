// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {AccountId, newAccountId} from "src/pools/types/AccountId.sol";

contract AccountIdTest is Test {
    function testAccountId(uint24 id, uint8 kind) public pure {
        AccountId accountId = newAccountId(id, kind);

        assertEq(uint24(bytes3(bytes4(AccountId.unwrap(accountId)))), id);
        assertEq(accountId.kind(), kind);
    }
}
