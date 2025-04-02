// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {PoolId, newPoolId} from "src/common/types/PoolId.sol";

contract PoolIdTest is Test {
    function testPoolId(uint48 id, uint16 chainId) public pure {
        vm.assume(id > 0);
        PoolId poolId = newPoolId(chainId, id);

        assertEq(poolId.isNull(), false);
        assertEq(poolId.chainId(), chainId);
        assertEq(uint48(poolId.raw()), id);
    }
}
