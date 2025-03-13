// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";

contract ShareClassIdTest is Test {
    function testShareClassId(bytes16 id) public pure {
        vm.assume(id > 0);
        ShareClassId shareClassId = ShareClassId.wrap(id);
        ShareClassId shareClassId2 = ShareClassId.wrap(id);

        assertEq(shareClassId.isNull(), false);
        assertEq(shareClassId.raw(), id);
        assertEq(shareClassId == shareClassId2, true);
    }
}
