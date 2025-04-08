// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "test/hub/integration/BaseTest.t.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";

contract TestBatchingAndPayment is BaseTest {
    /// forge-config: default.isolate = true
    function testExecuteNoSendNoPay() public {
        vm.prank(ADMIN);
        PoolId poolId = guardian.createPool(FM, USD);

        vm.startPrank(FM);

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(hub.setPoolMetadata.selector, "");

        hub.execute(poolId, cs);

        // Check no messages were sent as intended
        assertEq(cv.messageCount(), 0);
    }

    /// forge-config: default.isolate = true
    function testExecuteSendNoPay() public {
        vm.prank(ADMIN);
        PoolId poolId = guardian.createPool(FM, USD);

        vm.startPrank(FM);

        bytes[] memory cs = new bytes[](1);
        cs[0] = abi.encodeWithSelector(hub.notifyPool.selector, CHAIN_CV);

        vm.expectRevert(IGateway.NotEnoughTransactionGas.selector);
        hub.execute(poolId, cs);
    }

    /// Test the following:
    /// - multicall()
    ///   - execute(poolA)
    ///      - notifyPool()
    ///   - execute(poolA)
    ///      - notifyPool()
    ///
    /// will send one message. The batch sent is [NotifyPool, NotifyPool].
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallSamePool() public {
        vm.startPrank(ADMIN);
        PoolId poolA = guardian.createPool(FM, USD);

        vm.startPrank(FM);

        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeWithSelector(hub.notifyPool.selector, CHAIN_CV);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(hub.execute.selector, poolA, innerCalls);
        cs[c++] = abi.encodeWithSelector(hub.execute.selector, poolA, innerCalls);
        assertEq(c, cs.length);

        hub.multicall{value: GAS * 2}(cs);
    }

    /// Test the following:
    /// - multicall()
    ///   - execute(poolA)
    ///      - notifyPool()
    ///   - execute(poolB) <- different
    ///      - notifyPool()
    ///
    /// will send two messages because they are different pools.
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallDifferentPools() public {
        vm.startPrank(ADMIN);

        PoolId poolA = guardian.createPool(FM, USD);
        PoolId poolB = guardian.createPool(FM, USD);

        vm.startPrank(FM);

        bytes[] memory innerCalls = new bytes[](1);
        innerCalls[0] = abi.encodeWithSelector(hub.notifyPool.selector, CHAIN_CV);

        (bytes[] memory cs, uint256 c) = (new bytes[](2), 0);
        cs[c++] = abi.encodeWithSelector(hub.execute.selector, poolA, innerCalls);
        cs[c++] = abi.encodeWithSelector(hub.execute.selector, poolB, innerCalls);
        assertEq(c, cs.length);

        hub.multicall{value: GAS * 2}(cs);
    }
}
