// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "./BaseTest.sol";

contract TestBatchingAndPayment is BaseTest {
    /// Test the following:
    /// - multicall()
    ///    - notifyPool(poolA)
    ///    - notifyPool(poolA)
    ///
    /// will send one message. The batch sent is [NotifyPool, NotifyPool].
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallSamePool() public {
        PoolId poolA = hubRegistry.poolId(CHAIN_CP, 1);
        vm.startPrank(ADMIN);
        guardian.createPool(poolA, FM, USD_ID);

        vm.startPrank(FM);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(hub.notifyPool.selector, poolA, CHAIN_CV);
        cs[c++] = abi.encodeWithSelector(hub.notifyPool.selector, poolA, CHAIN_CV);
        assertEq(c, cs.length);

        hub.multicall{value: GAS * 2}(cs);
    }

    /// Test the following:
    /// - multicall()
    ///    - notifyPool(poolA)
    ///    - notifyPool(poolB)
    ///
    /// will send two messages because they are different pools.
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallDifferentPools() public {
        vm.startPrank(ADMIN);

        PoolId poolA = hubRegistry.poolId(CHAIN_CP, 1);
        PoolId poolB = hubRegistry.poolId(CHAIN_CP, 2);
        guardian.createPool(poolA, FM, USD_ID);
        guardian.createPool(poolB, FM, USD_ID);

        vm.startPrank(FM);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(hub.notifyPool.selector, poolA, CHAIN_CV);
        cs[c++] = abi.encodeWithSelector(hub.notifyPool.selector, poolB, CHAIN_CV);
        assertEq(c, cs.length);

        hub.multicall{value: GAS * 2}(cs);
    }
}
