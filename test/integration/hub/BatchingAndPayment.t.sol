// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {IAdapter} from "../../../src/core/messaging/interfaces/IAdapter.sol";
import {MAX_MESSAGE_COST} from "../../../src/core/messaging/interfaces/IGasService.sol";

import {CentrifugeIntegrationTest} from "../Integration.t.sol";

contract TestBatchingAndPayment is CentrifugeIntegrationTest {
    // Arbitrary target chain — only needs a registered mock adapter to accept sends
    uint16 constant TARGET_CHAIN = 99;
    uint128 constant GAS = MAX_MESSAGE_COST;

    address immutable FM = makeAddr("FM");
    address immutable REFUND = makeAddr("Refund");

    IAdapter[] mockAdapters;

    function setUp() public override {
        super.setUp();
        vm.deal(FM, 10 ether);

        // Configure a mock adapter for TARGET_CHAIN so hub can route cross-chain messages
        address mockAdapter = makeAddr("mockAdapter");
        vm.mockCall(mockAdapter, abi.encodeWithSignature("estimate(uint16,bytes,uint256)"), abi.encode(uint256(GAS)));
        vm.mockCall(mockAdapter, abi.encodeWithSignature("send(uint16,bytes,uint256,address)"), abi.encode(bytes32(0)));

        mockAdapters = new IAdapter[](1);
        mockAdapters[0] = IAdapter(mockAdapter);

        vm.prank(address(root));
        multiAdapter.setAdapters(TARGET_CHAIN, PoolId.wrap(0), mockAdapters, 1, 1);
    }

    /// Test that a multicall with two notifyPool calls for the same pool requires GAS per call.
    /// If only GAS (not GAS * 2) is provided the gateway will reject the batch as underpaid.
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallSamePool() public {
        PoolId poolA = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(poolA, FM, USD_ID);

        vm.startPrank(FM);
        hub.setAdapters{value: GAS}(poolA, TARGET_CHAIN, mockAdapters, new bytes32[](0), 1, 1, REFUND);

        bytes[] memory cs = new bytes[](2);
        cs[0] = abi.encodeWithSelector(hub.notifyPool.selector, poolA, TARGET_CHAIN, REFUND);
        cs[1] = abi.encodeWithSelector(hub.notifyPool.selector, poolA, TARGET_CHAIN, REFUND);

        hub.multicall{value: GAS * 2}(cs);
        vm.stopPrank();
    }

    /// Test that a multicall with notifyPool calls for two different pools requires GAS per call.
    /// Different pools produce separate outbound batches so each must be independently funded.
    ///
    /// forge-config: default.isolate = true
    function testMultipleMulticallDifferentPools() public {
        PoolId poolA = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        PoolId poolB = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 2);

        vm.startPrank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(poolA, FM, USD_ID);
        opsGuardian.createPool(poolB, FM, USD_ID);
        vm.stopPrank();

        vm.startPrank(FM);
        hub.setAdapters{value: GAS}(poolA, TARGET_CHAIN, mockAdapters, new bytes32[](0), 1, 1, REFUND);
        hub.setAdapters{value: GAS}(poolB, TARGET_CHAIN, mockAdapters, new bytes32[](0), 1, 1, REFUND);

        bytes[] memory cs = new bytes[](2);
        cs[0] = abi.encodeWithSelector(hub.notifyPool.selector, poolA, TARGET_CHAIN, REFUND);
        cs[1] = abi.encodeWithSelector(hub.notifyPool.selector, poolB, TARGET_CHAIN, REFUND);

        hub.multicall{value: GAS * 2}(cs);
        vm.stopPrank();
    }
}
