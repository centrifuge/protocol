// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {ShareClassId, newShareClassId} from "../../../src/common/types/ShareClassId.sol";

import "forge-std/Test.sol";

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

        assertEq(scId.raw(), bytes16((uint128(poolId.raw()) << 64) + index));
    }

    function testShareClassIdCollisionResistance(uint64 poolId1, uint64 poolId2, uint32 index1, uint32 index2)
        public
        pure
    {
        poolId1 = uint64(bound(poolId1, 2, type(uint64).max - 1));
        index1 = uint32(bound(index1, 2, type(uint32).max - 1));
        vm.assume(poolId2 != poolId1);
        vm.assume(index1 != index2);

        assertNotEq(
            newShareClassId(PoolId.wrap(poolId1), index1).raw(), newShareClassId(PoolId.wrap(poolId2), index2).raw()
        );

        ShareClassId scId1 = newShareClassId(PoolId.wrap(poolId1), index1);
        ShareClassId scId2 = newShareClassId(PoolId.wrap(poolId1 - 1), index1 + 1);
        ShareClassId scId3 = newShareClassId(PoolId.wrap(poolId1 + 1), index1 - 1);
        assertNotEq(scId1.raw(), scId2.raw());
        assertNotEq(scId1.raw(), scId3.raw());
        assertNotEq(scId2.raw(), scId3.raw());
    }
}
