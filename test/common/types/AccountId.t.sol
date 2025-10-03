// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AccountId} from "../../../src/common/types/AccountId.sol";

import "forge-std/Test.sol";

contract AccountIdTest is Test {
    function testAccountId(uint32 id) public pure {
        assertEq((AccountId.wrap(id).raw()), id);
    }
}
