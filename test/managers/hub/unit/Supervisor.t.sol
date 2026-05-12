// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHub, PendingOp} from "../../../../src/core/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IMulticall} from "../../../../src/misc/interfaces/IMulticall.sol";

import {Supervisor, SupervisorFactory} from "../../../../src/managers/hub/Supervisor.sol";
import {ISupervisor, TrustedCall} from "../../../../src/managers/hub/interfaces/ISupervisor.sol";

import "forge-std/Test.sol";

// ─── Mock contracts ─────────────────────────────────────────────────────────

contract MockGateway {
    address private _batcher;

    function withBatch(bytes memory data, address) external payable {
        _batcher = msg.sender;
        (bool success, bytes memory ret) = msg.sender.call{value: msg.value}(data);
        if (!success) {
            assembly {
                revert(add(32, ret), mload(ret))
            }
        }
        require(_batcher == address(0), "callback not locked");
    }

    function lockCallback() external {
        require(msg.sender == _batcher, "not batcher");
        _batcher = address(0);
    }
}

contract MockHub {
    address public hubRegistry_;
    address public gateway_;
    uint256 public lastValue;

    // Pending ops storage for testing
    mapping(bytes32 => PendingOp) public pendingOps;
    mapping(bytes32 => bool) public cancelled;

    constructor(address hubRegistry, address gateway) {
        hubRegistry_ = hubRegistry;
        gateway_ = gateway;
    }

    function hubRegistry() external view returns (IHubRegistry) {
        return IHubRegistry(hubRegistry_);
    }

    function gateway() external view returns (IGateway) {
        return IGateway(gateway_);
    }

    function doSomething(uint256 val) external payable {
        lastValue = val;
    }

    function alwaysReverts() external pure {
        revert("hub reverted");
    }

    function pending(bytes32 opId) external view returns (uint48, address, PoolId) {
        PendingOp memory op = pendingOps[opId];
        return (op.executeAfter, op.submitter, op.poolId);
    }

    function setPending(bytes32 opId, uint48 executeAfter, address submitter, PoolId poolId) external {
        pendingOps[opId] = PendingOp(executeAfter, submitter, poolId);
    }

    function execute(bytes calldata data) external payable {
        bytes32 opId = keccak256(data);
        require(pendingOps[opId].executeAfter != 0, "not pending");
        delete pendingOps[opId];
    }

    function cancel(bytes32 opId) external {
        require(pendingOps[opId].executeAfter != 0, "not pending");
        delete pendingOps[opId];
        cancelled[opId] = true;
    }

    function updateContract(
        PoolId,
        ShareClassId,
        uint16,
        bytes32,
        bytes calldata,
        uint128,
        address
    ) external payable {
        // no-op for testing
    }
}

contract MockHubRegistry {
    mapping(uint64 => mapping(address => bool)) public managers;

    function setManager(PoolId poolId, address who, bool canManage) external {
        managers[PoolId.unwrap(poolId)][who] = canManage;
    }

    function manager(PoolId poolId, address who) external view returns (bool) {
        return managers[PoolId.unwrap(poolId)][who];
    }
}

// ─── Base ───────────────────────────────────────────────────────────────────

abstract contract SupervisorTestBase is Test {
    PoolId constant POOL = PoolId.wrap(1);
    uint48 constant EXPIRY = 7 days;

    MockHub hub;
    MockHubRegistry registry;
    MockGateway mockGateway;

    address operator = makeAddr("operator");
    address contractUpdater = makeAddr("contractUpdater");
    address sentinel = makeAddr("sentinel");
    address unauthorized = makeAddr("unauthorized");

    function setUp() public virtual {
        mockGateway = new MockGateway();
        registry = new MockHubRegistry();
        hub = new MockHub(address(registry), address(mockGateway));
    }

    function _deploySupervisor() internal returns (Supervisor) {
        return new Supervisor(IHub(address(hub)), POOL, operator, contractUpdater, EXPIRY);
    }

    function _addSentinel(Supervisor supervisor, address s) internal {
        bytes memory payload = abi.encode(TrustedCall.AddSentinel, s);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    function _removeSentinel(Supervisor supervisor, address s) internal {
        bytes memory payload = abi.encode(TrustedCall.RemoveSentinel, s);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    /// @dev Helper to create Hub updateContract calldata for sentinel removal
    function _sentinelRemovalData(address s) internal pure returns (bytes memory) {
        bytes memory payload = abi.encode(TrustedCall.RemoveSentinel, s);
        return abi.encodeCall(
            IHub.updateContract,
            (POOL, ShareClassId.wrap(0), uint16(1), bytes32(0), payload, uint128(0), address(0))
        );
    }

    /// @dev Helper to set a pending op on the mock hub and return the opId
    function _setPending(bytes memory data, uint48 executeAfter) internal returns (bytes32 opId) {
        opId = keccak256(data);
        hub.setPending(opId, executeAfter, operator, POOL);
    }
}

// ─── Execute ────────────────────────────────────────────────────────────────

contract SupervisorExecuteTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
    }

    function testExecuteForwardsToHub() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.prank(operator);
        supervisor.forward(data);

        assertEq(hub.lastValue(), 42);
    }

    function testExecuteForwardsValue() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (99));

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        supervisor.forward{value: 0.5 ether}(data);

        assertEq(hub.lastValue(), 99);
        assertEq(address(hub).balance, 0.5 ether);
    }

    function testExecuteRevertsForNonOperator() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.expectRevert(ISupervisor.NotOperator.selector);
        vm.prank(unauthorized);
        supervisor.forward(data);
    }

    function testExecuteWrapsHubRevert() public {
        bytes memory data = abi.encodeCall(MockHub.alwaysReverts, ());

        vm.expectRevert();
        vm.prank(operator);
        supervisor.forward(data);
    }
}

// ─── Execute: multicall forbidden ───────────────────────────────────────────

contract SupervisorMulticallForbiddenTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
    }

    function testExecuteRevertsForMulticallSelector() public {
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeCall(MockHub.doSomething, (42));
        bytes memory multicallData = abi.encodeWithSignature("multicall(bytes[])", inner);

        vm.expectRevert(ISupervisor.MulticallForbidden.selector);
        vm.prank(operator);
        supervisor.forward(multicallData);
    }
}

// ─── ExecutePending ─────────────────────────────────────────────────────────

contract SupervisorExecutePendingTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
        _addSentinel(supervisor, sentinel);
    }

    function testExecutePendingByOperator() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(data, executeAfter);

        vm.warp(executeAfter);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testExecutePendingBySentinel() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(data, executeAfter);

        vm.warp(executeAfter);
        vm.prank(sentinel);
        supervisor.execute(data);
    }

    function testExecutePendingRevertsForUnauthorized() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(data, executeAfter);

        vm.warp(executeAfter);
        vm.expectRevert(ISupervisor.NotOperatorOrSentinel.selector);
        vm.prank(unauthorized);
        supervisor.execute(data);
    }

    function testExecutePendingRevertsWhenExpired() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(data, executeAfter);

        vm.warp(executeAfter + EXPIRY + 1);
        vm.expectRevert(ISupervisor.TimelockExpired.selector);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testExecutePendingWithinExpiryWindow() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(data, executeAfter);

        vm.warp(executeAfter + EXPIRY);
        vm.prank(operator);
        supervisor.execute(data);
    }
}

// ─── CancelPending ──────────────────────────────────────────────────────────

contract SupervisorCancelPendingTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
        _addSentinel(supervisor, sentinel);
    }

    function testOperatorCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        bytes32 opId = _setPending(data, uint48(block.timestamp) + 1 days);

        vm.prank(operator);
        supervisor.cancel(data);

        assertTrue(hub.cancelled(opId));
    }

    function testSentinelCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        bytes32 opId = _setPending(data, uint48(block.timestamp) + 1 days);

        vm.prank(sentinel);
        supervisor.cancel(data);

        assertTrue(hub.cancelled(opId));
    }

    function testUnauthorizedCannotCancel() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        _setPending(data, uint48(block.timestamp) + 1 days);

        vm.expectRevert(ISupervisor.NotOperatorOrSentinel.selector);
        vm.prank(unauthorized);
        supervisor.cancel(data);
    }

    function testSentinelCannotCancelOwnRemovalWithMultipleSentinels() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes memory data = _sentinelRemovalData(sentinel);
        _setPending(data, uint48(block.timestamp) + 1 days);

        vm.expectRevert(ISupervisor.CannotSelfCancel.selector);
        vm.prank(sentinel);
        supervisor.cancel(data);
    }

    function testSoleSentinelCanCancelOwnRemoval() public {
        bytes memory data = _sentinelRemovalData(sentinel);
        _setPending(data, uint48(block.timestamp) + 1 days);

        // Sole sentinel — self-cancel is allowed
        vm.prank(sentinel);
        supervisor.cancel(data);

        assertTrue(hub.cancelled(keccak256(data)));
    }

    function testSentinelCanCancelOtherSentinelRemoval() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes memory data = _sentinelRemovalData(sentinel2);
        _setPending(data, uint48(block.timestamp) + 1 days);

        // sentinel cancels sentinel2's removal — allowed
        vm.prank(sentinel);
        supervisor.cancel(data);

        assertTrue(hub.cancelled(keccak256(data)));
    }

    function testOperatorCanCancelSentinelRemoval() public {
        bytes memory data = _sentinelRemovalData(sentinel);
        _setPending(data, uint48(block.timestamp) + 1 days);

        // Operator is never restricted by self-cancel check
        vm.prank(operator);
        supervisor.cancel(data);

        assertTrue(hub.cancelled(keccak256(data)));
    }

    function testNonUpdateContractDataSkipsSelfRemovalCheck() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        // Regular Hub call, not an updateContract — self-removal check doesn't apply
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));
        _setPending(data, uint48(block.timestamp) + 1 days);

        vm.prank(sentinel);
        supervisor.cancel(data);

        assertTrue(hub.cancelled(keccak256(data)));
    }
}

// ─── Sentinel management (trustedCall) ──────────────────────────────────────

contract SupervisorSentinelTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
    }

    function testAddSentinel() public {
        _addSentinel(supervisor, sentinel);

        assertTrue(supervisor.sentinels(sentinel));
        assertEq(supervisor.sentinelCount(), 1);
    }

    function testAddMultipleSentinels() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel);
        _addSentinel(supervisor, sentinel2);

        assertTrue(supervisor.sentinels(sentinel));
        assertTrue(supervisor.sentinels(sentinel2));
        assertEq(supervisor.sentinelCount(), 2);
    }

    function testAddSentinelRevertsForNonContractUpdater() public {
        bytes memory payload = abi.encode(TrustedCall.AddSentinel, sentinel);

        vm.expectRevert(ISupervisor.NotContractUpdater.selector);
        vm.prank(operator);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    function testAddSentinelRevertsForZeroAddress() public {
        bytes memory payload = abi.encode(TrustedCall.AddSentinel, address(0));

        vm.expectRevert(ISupervisor.ZeroAddress.selector);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    function testAddSentinelRevertsIfAlreadySentinel() public {
        _addSentinel(supervisor, sentinel);

        bytes memory payload = abi.encode(TrustedCall.AddSentinel, sentinel);

        vm.expectRevert(ISupervisor.AlreadySentinel.selector);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    function testRemoveSentinel() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel);
        _addSentinel(supervisor, sentinel2);

        _removeSentinel(supervisor, sentinel);

        assertFalse(supervisor.sentinels(sentinel));
        assertTrue(supervisor.sentinels(sentinel2));
        assertEq(supervisor.sentinelCount(), 1);
    }

    function testRemoveSentinelRevertsForNonSentinel() public {
        bytes memory payload = abi.encode(TrustedCall.RemoveSentinel, sentinel);

        vm.expectRevert(ISupervisor.NotSentinel.selector);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    function testRemoveLastSentinelReverts() public {
        _addSentinel(supervisor, sentinel);

        bytes memory payload = abi.encode(TrustedCall.RemoveSentinel, sentinel);

        vm.expectRevert(ISupervisor.LastSentinel.selector);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    function testEmitsAddSentinelEvent() public {
        bytes memory payload = abi.encode(TrustedCall.AddSentinel, sentinel);

        vm.expectEmit();
        emit ISupervisor.AddSentinel(sentinel);

        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }

    function testEmitsRemoveSentinelEvent() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel);
        _addSentinel(supervisor, sentinel2);

        bytes memory payload = abi.encode(TrustedCall.RemoveSentinel, sentinel);

        vm.expectEmit();
        emit ISupervisor.RemoveSentinel(sentinel);

        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL, ShareClassId.wrap(0), payload);
    }
}

// ─── Multicall batching ─────────────────────────────────────────────────────

contract SupervisorMulticallTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
    }

    function testMulticallBatchesExecuteCalls() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Supervisor.forward, (abi.encodeCall(MockHub.doSomething, (1))));
        calls[1] = abi.encodeCall(Supervisor.forward, (abi.encodeCall(MockHub.doSomething, (2))));

        vm.prank(operator);
        supervisor.multicall(calls);

        assertEq(hub.lastValue(), 2);
    }

    function testMulticallRevertsForNonOperator() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Supervisor.forward, (abi.encodeCall(MockHub.doSomething, (1))));

        vm.expectRevert();
        vm.prank(unauthorized);
        supervisor.multicall(calls);
    }
}

// ─── Factory ────────────────────────────────────────────────────────────────

contract SupervisorFactoryTest is Test {
    PoolId constant POOL = PoolId.wrap(1);

    MockHubRegistry registry;
    MockHub hub;
    SupervisorFactory factory;

    function setUp() public {
        registry = new MockHubRegistry();
        hub = new MockHub(address(registry), address(new MockGateway()));
        factory = new SupervisorFactory(IHub(address(hub)));
    }

    function testNewSupervisor() public {
        address op = makeAddr("operator");
        address cu = makeAddr("contractUpdater");
        ISupervisor supervisor = factory.newSupervisor(POOL, op, cu, 7 days);

        assertEq(address(supervisor.hub()), address(hub));
        assertEq(PoolId.unwrap(supervisor.poolId()), PoolId.unwrap(POOL));
        assertEq(supervisor.operator(), op);
        assertEq(supervisor.contractUpdater(), cu);
        assertEq(supervisor.expiryWindow(), 7 days);
    }
}
