// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "test/pools/integration/BaseTest.t.sol";

contract TestBatchingAndPayment is BaseTest {
    /// forge-config: default.isolate = true
    function testExecuteNoSendNoPay() public {
        vm.prank(ADMIN);
        PoolId poolId = guardian.createPool(FM, USD, multiShareClass);

        vm.startPrank(FM);

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(poolRouter.setPoolMetadata.selector, "");

        poolRouter.execute(poolId, cs);

        // Check no messages were sent as intended
        assertEq(cv.messageCount(), 0);
    }

    /// forge-config: default.isolate = true
    function testExecuteSendNoPay() public {
        vm.prank(ADMIN);
        PoolId poolId = guardian.createPool(FM, USD, multiShareClass);

        vm.startPrank(FM);

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CHAIN_CV);

        vm.expectRevert(bytes("Gateway/not-enough-gas-funds"));
        poolRouter.execute(poolId, cs);
    }

    /// Test the following:
    /// - multicall()
    ///   - execute(poolA)
    ///      - notifyPool()
    ///   - execute(poolA)
    ///      - notifyPool()
    ///
    /// will pay only for one message. The batch sent is [NotifyPool, NotifyPool].
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallSamePool() public {
        vm.startPrank(ADMIN);
        PoolId poolA = guardian.createPool(FM, USD, multiShareClass);

        vm.startPrank(FM);

        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CHAIN_CV);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.execute.selector, poolA, innerCalls);
        cs[c++] = abi.encodeWithSelector(poolRouter.execute.selector, poolA, innerCalls);
        assertEq(c, cs.length);

        poolRouter.multicall{value: GAS * 2}(cs);
    }

    /// Test the following:
    /// - multicall()
    ///   - execute(poolA)
    ///      - notifyPool()
    ///   - execute(poolB) <- different
    ///      - notifyPool()
    ///
    /// will pay only for two messages because they are different pools.
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallDifferentPools() public {
        vm.startPrank(ADMIN);

        PoolId poolA = guardian.createPool(FM, USD, multiShareClass);
        PoolId poolB = guardian.createPool(FM, USD, multiShareClass);

        vm.startPrank(FM);

        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeWithSelector(poolRouter.notifyPool.selector, CHAIN_CV);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(poolRouter.execute.selector, poolA, innerCalls);
        cs[c++] = abi.encodeWithSelector(poolRouter.execute.selector, poolB, innerCalls);
        assertEq(c, cs.length);

        poolRouter.multicall{value: GAS * 2}(cs);
    }
}
