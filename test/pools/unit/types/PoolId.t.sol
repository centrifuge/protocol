// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {PoolId, newPoolId} from "src/common/types/PoolId.sol";

contract PoolIdTest is Test {
    function testPoolId(uint32 id) public view {
        vm.assume(id > 0);
        PoolId poolId = newPoolId(id);

        assertEq(poolId.isNull(), false);
        assertEq(poolId.chainId(), uint32(block.chainid));
        assertEq(uint32(poolId.raw()), id);
    }
}
