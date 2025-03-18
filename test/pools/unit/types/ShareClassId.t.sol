// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {ShareClassId, newShareClassId} from "src/pools/types/ShareClassId.sol";
import {PoolId, newPoolId} from "src/pools/types/PoolId.sol";

contract ShareClassIdTest is Test {
    function testShareClassId(bytes16 id) public pure {
        vm.assume(id > 0);
        ShareClassId shareClassId = ShareClassId.wrap(id);
        ShareClassId shareClassId2 = ShareClassId.wrap(id);

        assertEq(shareClassId.isNull(), false);
        assertEq(shareClassId.raw(), id);
        assertEq(shareClassId == shareClassId2, true);
    }

    function testNewShareClassId(uint32 poolId_, uint32 index) public view {
        PoolId poolId = newPoolId(poolId_);
        ShareClassId scId = newShareClassId(poolId, index);

        assertEq(scId.raw(), bytes16(uint128(poolId.raw() + index)));
    }
}
