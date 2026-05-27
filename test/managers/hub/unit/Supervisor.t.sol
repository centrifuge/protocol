// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHub, PendingOp} from "../../../../src/core/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";

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
    PoolId public lastProposedPoolId;
    bytes[] public lastProposedCalls;
    bytes public lastProposedCallback;
    uint64 public mockNonce = 1;
    bool public lastExecuted;
    bool public lastCancelled;

    mapping(bytes32 => PendingOp) public pendingOps;
    mapping(bytes32 => bool) public cancelled;

    constructor(address hubRegistry_input, address gateway_input) {
        hubRegistry_ = hubRegistry_input;
        gateway_ = gateway_input;
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

    function pending(bytes32 opId) external view returns (uint48, address) {
        PendingOp memory op = pendingOps[opId];
        return (op.executeAfter, op.submitter);
    }

    function setPending(bytes32 opId, uint48 executeAfter, address submitter) external {
        pendingOps[opId] = PendingOp(executeAfter, submitter);
    }

    function await(PoolId poolId, bytes[] calldata calls, bytes calldata callback)
        external
        returns (uint64 nonce, bytes32 opId)
    {
        lastProposedPoolId = poolId;
        delete lastProposedCalls;
        for (uint256 i; i < calls.length; i++) lastProposedCalls.push(calls[i]);
        lastProposedCallback = callback;
        nonce = mockNonce++;
        opId = keccak256(abi.encode(poolId, nonce, calls, callback));
    }

    function awaitAndExecute(PoolId poolId, bytes[] calldata calls, bytes calldata callback)
        external
        payable
        returns (uint64 nonce, bytes32 opId)
    {
        lastProposedPoolId = poolId;
        delete lastProposedCalls;
        for (uint256 i; i < calls.length; i++) lastProposedCalls.push(calls[i]);
        lastProposedCallback = callback;
        nonce = mockNonce++;
        opId = keccak256(abi.encode(poolId, nonce, calls, callback));
        lastExecuted = true;
    }

    function execute(PoolId poolId, uint64 nonce, bytes[] calldata calls, bytes calldata callback) external payable {
        bytes32 opId = keccak256(abi.encode(poolId, nonce, calls, callback));
        require(pendingOps[opId].executeAfter != 0, "not pending");
        delete pendingOps[opId];
        lastExecuted = true;
    }

    function cancel(PoolId poolId, uint64 nonce, bytes[] calldata calls, bytes calldata callback) external {
        bytes32 opId = keccak256(abi.encode(poolId, nonce, calls, callback));
        require(pendingOps[opId].executeAfter != 0, "not pending");
        delete pendingOps[opId];
        cancelled[opId] = true;
        lastCancelled = true;
    }

    function updateContract(PoolId, ShareClassId, uint16, bytes32, bytes calldata, uint128, address)
        external
        payable
    {
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
    uint64 constant NONCE = 1;

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

    function _sentinelRemovalBatch(address s) internal pure returns (bytes[] memory calls) {
        bytes memory payload = abi.encode(TrustedCall.RemoveSentinel, s);
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            IHub.updateContract,
            (POOL, ShareClassId.wrap(0), uint16(1), bytes32(0), payload, uint128(0), address(0))
        );
    }

    function _doSomethingBatch(uint256 val) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(MockHub.doSomething, (val));
    }

    function _setPending(bytes[] memory calls, bytes memory callback, uint48 executeAfter)
        internal
        returns (bytes32 opId)
    {
        opId = keccak256(abi.encode(POOL, NONCE, calls, callback));
        hub.setPending(opId, executeAfter, operator);
    }
}

// ─── Await ──────────────────────────────────────────────────────────────────

contract SupervisorAwaitTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
    }

    function testAwaitForwardsToHub() public {
        bytes[] memory calls = _doSomethingBatch(42);

        vm.prank(operator);
        (uint64 nonce, bytes32 opId) = supervisor.await(calls, "");

        assertEq(nonce, 1);
        assertEq(PoolId.unwrap(hub.lastProposedPoolId()), PoolId.unwrap(POOL));
        assertEq(hub.lastProposedCalls(0), calls[0]);
        assertEq(opId, keccak256(abi.encode(POOL, uint64(1), calls, "")));
    }

    function testAwaitPassesCallback() public {
        bytes[] memory calls = _doSomethingBatch(7);
        bytes memory cb = abi.encodeWithSignature("onExecuted()");

        vm.prank(operator);
        supervisor.await(calls, cb);

        assertEq(hub.lastProposedCallback(), cb);
    }

    function testAwaitRevertsForNonOperator() public {
        bytes[] memory calls = _doSomethingBatch(42);

        vm.expectRevert(ISupervisor.NotOperator.selector);
        vm.prank(unauthorized);
        supervisor.await(calls, "");
    }

    function testAwaitAndExecuteForwardsValue() public {
        bytes[] memory calls = _doSomethingBatch(99);

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        supervisor.awaitAndExecute{value: 0.5 ether}(calls, "");

        assertEq(address(hub).balance, 0.5 ether);
        assertTrue(hub.lastExecuted());
    }

    function testAwaitAndExecuteRevertsForNonOperator() public {
        bytes[] memory calls = _doSomethingBatch(42);

        vm.expectRevert(ISupervisor.NotOperator.selector);
        vm.prank(unauthorized);
        supervisor.awaitAndExecute(calls, "");
    }
}

// ─── Execute ────────────────────────────────────────────────────────────────

contract SupervisorExecuteTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
        _addSentinel(supervisor, sentinel);
    }

    function testExecuteByOperator() public {
        bytes[] memory calls = _doSomethingBatch(42);
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(calls, "", executeAfter);

        vm.warp(executeAfter);
        vm.prank(operator);
        supervisor.execute(NONCE, calls, "");

        assertTrue(hub.lastExecuted());
    }

    function testExecuteBySentinel() public {
        bytes[] memory calls = _doSomethingBatch(42);
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(calls, "", executeAfter);

        vm.warp(executeAfter);
        vm.prank(sentinel);
        supervisor.execute(NONCE, calls, "");

        assertTrue(hub.lastExecuted());
    }

    function testExecuteRevertsForUnauthorized() public {
        bytes[] memory calls = _doSomethingBatch(42);
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(calls, "", executeAfter);

        vm.warp(executeAfter);
        vm.expectRevert(ISupervisor.NotOperatorOrSentinel.selector);
        vm.prank(unauthorized);
        supervisor.execute(NONCE, calls, "");
    }

    function testExecuteRevertsWhenExpired() public {
        bytes[] memory calls = _doSomethingBatch(42);
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(calls, "", executeAfter);

        vm.warp(executeAfter + EXPIRY + 1);
        vm.expectRevert(ISupervisor.TimelockExpired.selector);
        vm.prank(operator);
        supervisor.execute(NONCE, calls, "");
    }

    function testExecuteWithinExpiryWindow() public {
        bytes[] memory calls = _doSomethingBatch(42);
        uint48 executeAfter = uint48(block.timestamp) + 1 days;
        _setPending(calls, "", executeAfter);

        vm.warp(executeAfter + EXPIRY);
        vm.prank(operator);
        supervisor.execute(NONCE, calls, "");
    }
}

// ─── Cancel ─────────────────────────────────────────────────────────────────

contract SupervisorCancelTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor();
        _addSentinel(supervisor, sentinel);
    }

    function testOperatorCanCancel() public {
        bytes[] memory calls = _doSomethingBatch(42);
        bytes32 opId = _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.prank(operator);
        supervisor.cancel(NONCE, calls, "");

        assertTrue(hub.cancelled(opId));
    }

    function testSentinelCanCancel() public {
        bytes[] memory calls = _doSomethingBatch(42);
        bytes32 opId = _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.prank(sentinel);
        supervisor.cancel(NONCE, calls, "");

        assertTrue(hub.cancelled(opId));
    }

    function testUnauthorizedCannotCancel() public {
        bytes[] memory calls = _doSomethingBatch(42);
        _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.expectRevert(ISupervisor.NotOperatorOrSentinel.selector);
        vm.prank(unauthorized);
        supervisor.cancel(NONCE, calls, "");
    }

    function testSentinelCannotCancelOwnRemovalWithMultipleSentinels() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes[] memory calls = _sentinelRemovalBatch(sentinel);
        _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.expectRevert(ISupervisor.CannotSelfCancel.selector);
        vm.prank(sentinel);
        supervisor.cancel(NONCE, calls, "");
    }

    function testSentinelCannotCancelBatchContainingOwnRemoval() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes[] memory removal = _sentinelRemovalBatch(sentinel);
        bytes[] memory other = _doSomethingBatch(42);
        bytes[] memory calls = new bytes[](2);
        calls[0] = other[0];
        calls[1] = removal[0];
        _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.expectRevert(ISupervisor.CannotSelfCancel.selector);
        vm.prank(sentinel);
        supervisor.cancel(NONCE, calls, "");
    }

    function testSoleSentinelCanCancelOwnRemoval() public {
        bytes[] memory calls = _sentinelRemovalBatch(sentinel);
        bytes32 opId = _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.prank(sentinel);
        supervisor.cancel(NONCE, calls, "");

        assertTrue(hub.cancelled(opId));
    }

    function testSentinelCanCancelOtherSentinelRemoval() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes[] memory calls = _sentinelRemovalBatch(sentinel2);
        bytes32 opId = _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.prank(sentinel);
        supervisor.cancel(NONCE, calls, "");

        assertTrue(hub.cancelled(opId));
    }

    function testOperatorCanCancelSentinelRemoval() public {
        bytes[] memory calls = _sentinelRemovalBatch(sentinel);
        bytes32 opId = _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.prank(operator);
        supervisor.cancel(NONCE, calls, "");

        assertTrue(hub.cancelled(opId));
    }

    function testNonUpdateContractCallsSkipSelfRemovalCheck() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes[] memory calls = _doSomethingBatch(42);
        bytes32 opId = _setPending(calls, "", uint48(block.timestamp) + 1 days);

        vm.prank(sentinel);
        supervisor.cancel(NONCE, calls, "");

        assertTrue(hub.cancelled(opId));
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
