// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {ShareClassId, newShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId, newPoolId} from "src/common/types/PoolId.sol";

contract ShareClassIdTest is Test {
    function testShareClassId(bytes16 id) public pure {
        vm.assume(id > 0);
        ShareClassId scId = ShareClassId.wrap(id);
        ShareClassId scId2 = ShareClassId.wrap(id);

        assertEq(scId.isNull(), false);
        assertEq(scId.raw(), id);
        assertEq(scId == scId2, true);
    }

    function testNewShareClassId(uint64 poolId_, uint32 index) public pure {
        PoolId poolId = PoolId.wrap(poolId_);
        ShareClassId scId = newShareClassId(poolId, index);

        assertEq(scId.raw(), bytes16(uint128(poolId.raw()) + index));
    }
}
