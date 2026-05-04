// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";

import {Supervisor, SupervisorFactory} from "../../../../src/managers/hub/Supervisor.sol";
import {ISupervisor, IManifest, SupervisorConfig} from "../../../../src/managers/hub/interfaces/ISupervisor.sol";

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

    function timelocked(uint256 val) external payable {
        lastValue = val;
    }

    function hookedFn(uint256 val) external payable {
        lastValue = val;
    }

    function alwaysReverts() external pure {
        revert("hub reverted");
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

contract MockManifest is IManifest {
    bool public shouldRevert;
    uint48 public extraDelay;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function setExtraDelay(uint48 d) external {
        extraDelay = d;
    }

    error Blocked();

    function check(PoolId, address, bytes calldata) external returns (uint48) {
        if (shouldRevert) revert Blocked();
        return extraDelay;
    }
}

// ─── Base ───────────────────────────────────────────────────────────────────

abstract contract SupervisorTestBase is Test {
    PoolId constant POOL = PoolId.wrap(1);

    MockHub hub;
    MockHubRegistry registry;
    MockGateway mockGateway;

    address operator = makeAddr("operator");
    address sentinel = makeAddr("sentinel");
    address unauthorized = makeAddr("unauthorized");

    bytes4 constant TIMELOCKED_SEL = MockHub.timelocked.selector;
    bytes4 constant HOOKED_SEL = MockHub.hookedFn.selector;

    uint48 constant TIMELOCK = 2 days;
    uint48 constant EXPIRY = 7 days;

    function _deploySupervisor(IManifest hook) internal returns (Supervisor) {
        bytes4[] memory timelockSels = new bytes4[](1);
        timelockSels[0] = TIMELOCKED_SEL;

        bytes4[] memory hookSels = new bytes4[](1);
        hookSels[0] = HOOKED_SEL;

        SupervisorConfig memory config =
            SupervisorConfig(timelockSels, hookSels, TIMELOCK, EXPIRY, hook);

        return new Supervisor(IHub(address(hub)), POOL, operator, config);
    }

    function setUp() public virtual {
        mockGateway = new MockGateway();
        registry = new MockHubRegistry();
        hub = new MockHub(address(registry), address(mockGateway));
    }

    /// @dev Helper to add a sentinel through the timelock flow.
    function _addSentinel(Supervisor supervisor, address s) internal {
        bytes memory data = abi.encodeCall(Supervisor.addSentinel, (s));
        vm.prank(operator);
        supervisor.submit(data);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(operator);
        supervisor.addSentinel(s);
    }
}

// ─── Execute (non-timelocked) ───────────────────────────────────────────────

contract SupervisorExecuteTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor(IManifest(address(0)));
    }

    function testExecuteForwardsToHub() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.prank(operator);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testExecuteForwardsValue() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (99));

        vm.deal(operator, 1 ether);
        vm.prank(operator);
        supervisor.execute{value: 0.5 ether}(data);

        assertEq(hub.lastValue(), 99);
        assertEq(address(hub).balance, 0.5 ether);
    }

    function testExecuteRevertsForNonManager() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.expectRevert(ISupervisor.NotOperator.selector);
        vm.prank(unauthorized);
        supervisor.execute(data);
    }

    function testExecuteWrapsHubRevert() public {
        bytes memory data = abi.encodeCall(MockHub.alwaysReverts, ());

        vm.expectRevert();
        vm.prank(operator);
        supervisor.execute(data);
    }
}

// ─── Timelock ───────────────────────────────────────────────────────────────

contract SupervisorTimelockTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor(IManifest(address(0)));
    }

    function testTimelockRequiresSubmitFirst() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testTimelockFullFlow() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        // Too early
        vm.expectRevert();
        vm.prank(operator);
        supervisor.execute(data);

        // After delay
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(operator);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testTimelockExpires() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        vm.warp(block.timestamp + TIMELOCK + EXPIRY + 1);

        vm.expectRevert(ISupervisor.TimelockExpired.selector);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testTimelockCannotSubmitTwice() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.OperationAlreadyPending.selector);
        vm.prank(operator);
        supervisor.submit(data);
    }

    function testTimelockCannotReplay() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(operator);
        supervisor.execute(data);

        // Second execute should fail
        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testSubmitRevertsForNonTimelocked() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.expectRevert(ISupervisor.TimelockNotSet.selector);
        vm.prank(operator);
        supervisor.submit(data);
    }

    function testSubmitRevertsForNonManager() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.expectRevert(ISupervisor.NotOperator.selector);
        vm.prank(unauthorized);
        supervisor.submit(data);
    }
}

// ─── Cancel ─────────────────────────────────────────────────────────────────

contract SupervisorCancelTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor(IManifest(address(0)));
        _addSentinel(supervisor, sentinel);
    }

    function testManagerCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        vm.prank(operator);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }

    function testSentinelCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        vm.prank(sentinel);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }

    function testUnauthorizedCannotCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.NotOperatorOrSentinel.selector);
        vm.prank(unauthorized);
        supervisor.cancel(data);
    }

    function testCannotCancelNonPending() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (99));

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(operator);
        supervisor.cancel(data);
    }

    function testCancelPreventsExecution() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(operator);
        supervisor.submit(data);

        vm.prank(sentinel);
        supervisor.cancel(data);

        vm.warp(block.timestamp + TIMELOCK);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testSentinelCannotCancelOwnRemovalWithMultipleSentinels() public {
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(operator);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.CannotSelfCancel.selector);
        vm.prank(sentinel);
        supervisor.cancel(data);
    }

    function testSoleSentinelCanCancelOwnRemoval() public {
        // Only one sentinel set (from setUp)
        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(operator);
        supervisor.submit(data);

        vm.prank(sentinel);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }
}

// ─── Manifest hook ──────────────────────────────────────────────────────────

contract SupervisorManifestHookTest is SupervisorTestBase {
    Supervisor supervisor;
    MockManifest hook;

    function setUp() public override {
        super.setUp();
        hook = new MockManifest();
        supervisor = _deploySupervisor(IManifest(address(hook)));
    }

    function testHookPassesForNonHookedSelector() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.prank(operator);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testHookBlocksWhenReverting() public {
        hook.setShouldRevert(true);
        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.expectRevert(MockManifest.Blocked.selector);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testHookAllowsWhenPassing() public {
        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.prank(operator);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }
}

// ─── Sentinel management ────────────────────────────────────────────────────

contract SupervisorSentinelTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor(IManifest(address(0)));
    }

    function testAddSentinelRequiresTimelock() public {
        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(operator);
        supervisor.addSentinel(sentinel);
    }

    function testAddSentinelFullFlow() public {
        _addSentinel(supervisor, sentinel);
        assertTrue(supervisor.sentinels(sentinel));
        assertEq(supervisor.sentinelCount(), 1);
    }

    function testAddSentinelRevertsForNonOperator() public {
        bytes memory data = abi.encodeCall(Supervisor.addSentinel, (sentinel));
        vm.expectRevert(ISupervisor.NotOperator.selector);
        vm.prank(unauthorized);
        supervisor.submit(data);
    }

    function testAddSentinelRevertsForZeroAddress() public {
        bytes memory data = abi.encodeCall(Supervisor.addSentinel, (address(0)));
        vm.prank(operator);
        supervisor.submit(data);
        vm.warp(block.timestamp + TIMELOCK);

        vm.expectRevert(ISupervisor.ZeroAddress.selector);
        vm.prank(operator);
        supervisor.addSentinel(address(0));
    }

    function testAddSentinelRevertsIfAlreadySentinel() public {
        _addSentinel(supervisor, sentinel);

        bytes memory data = abi.encodeCall(Supervisor.addSentinel, (sentinel));
        vm.prank(operator);
        supervisor.submit(data);
        vm.warp(block.timestamp + TIMELOCK);

        vm.expectRevert(ISupervisor.AlreadySentinel.selector);
        vm.prank(operator);
        supervisor.addSentinel(sentinel);
    }

    function testRemoveSentinelRequiresTimelock() public {
        _addSentinel(supervisor, sentinel);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(operator);
        supervisor.removeSentinel(sentinel);
    }

    function testRemoveSentinelFullFlow() public {
        _addSentinel(supervisor, sentinel);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(operator);
        supervisor.submit(data);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(operator);
        supervisor.removeSentinel(sentinel);

        assertFalse(supervisor.sentinels(sentinel));
    }

    function testRemoveSentinelTooEarly() public {
        _addSentinel(supervisor, sentinel);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(operator);
        supervisor.submit(data);

        vm.expectRevert();
        vm.prank(operator);
        supervisor.removeSentinel(sentinel);

        assertTrue(supervisor.sentinels(sentinel));
    }

    function testSoleSentinelCanVetoOwnRemoval() public {
        _addSentinel(supervisor, sentinel);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(operator);
        supervisor.submit(data);

        vm.prank(sentinel);
        supervisor.cancel(data);

        vm.warp(block.timestamp + TIMELOCK);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(operator);
        supervisor.removeSentinel(sentinel);

        assertTrue(supervisor.sentinels(sentinel));
    }

    function testOtherSentinelCanVetoRemoval() public {
        _addSentinel(supervisor, sentinel);
        address sentinel2 = makeAddr("sentinel2");
        _addSentinel(supervisor, sentinel2);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(operator);
        supervisor.submit(data);

        vm.prank(sentinel2);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }
}

// ─── Multicall ─────────────────────────────────────────────────────────────

contract SupervisorMulticallTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor(IManifest(address(0)));
    }

    function testMulticallBatchesExecuteCalls() public {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Supervisor.execute, (abi.encodeCall(MockHub.doSomething, (1))));
        calls[1] = abi.encodeCall(Supervisor.execute, (abi.encodeCall(MockHub.doSomething, (2))));

        vm.prank(operator);
        supervisor.multicall(calls);

        // Last call wins
        assertEq(hub.lastValue(), 2);
    }

    function testMulticallSubmitAndCancel() public {
        bytes memory timelockData = abi.encodeCall(MockHub.timelocked, (42));

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(Supervisor.submit, (timelockData));
        calls[1] = abi.encodeCall(Supervisor.cancel, (timelockData));

        vm.prank(operator);
        supervisor.multicall(calls);

        assertEq(supervisor.pending(timelockData), 0);
    }

    function testMulticallRevertsForNonOperator() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(Supervisor.execute, (abi.encodeCall(MockHub.doSomething, (1))));

        vm.expectRevert();
        vm.prank(unauthorized);
        supervisor.multicall(calls);
    }
}

// ─── Manifest additional delay ─────────────────────────────────────────────

contract SupervisorManifestDelayTest is SupervisorTestBase {
    Supervisor supervisor;
    MockManifest hook;

    function setUp() public override {
        super.setUp();
        hook = new MockManifest();
        // Deploy with timelocked + hooked on same selector
        bytes4[] memory timelockSels = new bytes4[](1);
        timelockSels[0] = MockHub.hookedFn.selector;
        bytes4[] memory hookSels = new bytes4[](1);
        hookSels[0] = MockHub.hookedFn.selector;

        SupervisorConfig memory config =
            SupervisorConfig(timelockSels, hookSels, TIMELOCK, EXPIRY, IManifest(address(hook)));
        supervisor = new Supervisor(IHub(address(hub)), POOL, operator, config);
    }

    function testAdditionalDelayExtendsTimelock() public {
        uint48 extra = 1 days;
        hook.setExtraDelay(extra);

        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.prank(operator);
        supervisor.submit(data);

        // Warp past base delay but not additional delay
        vm.warp(block.timestamp + TIMELOCK);

        vm.expectRevert();
        vm.prank(operator);
        supervisor.execute(data);

        // Warp past additional delay
        vm.warp(block.timestamp + extra);
        vm.prank(operator);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testAdditionalDelayExpiryWindowStartsAfterFullDelay() public {
        uint48 extra = 1 days;
        hook.setExtraDelay(extra);

        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.prank(operator);
        supervisor.submit(data);

        // Warp past base delay + additional delay + expiry window
        vm.warp(block.timestamp + TIMELOCK + extra + EXPIRY + 1);

        vm.expectRevert(ISupervisor.TimelockExpired.selector);
        vm.prank(operator);
        supervisor.execute(data);
    }

    function testAdditionalDelayExecutableWithinExpiryWindow() public {
        uint48 extra = 1 days;
        hook.setExtraDelay(extra);

        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.prank(operator);
        supervisor.submit(data);

        // Warp to end of expiry window (should still work)
        vm.warp(block.timestamp + TIMELOCK + extra + EXPIRY);
        vm.prank(operator);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }
}

// ─── Multicall forbidden ──────────────────────────────────────────────────

contract SupervisorMulticallForbiddenTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor(IManifest(address(0)));
    }

    function testExecuteRevertsForMulticallSelector() public {
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeCall(MockHub.doSomething, (42));
        bytes memory multicallData = abi.encodeWithSignature("multicall(bytes[])", inner);

        vm.expectRevert(ISupervisor.MulticallForbidden.selector);
        vm.prank(operator);
        supervisor.execute(multicallData);
    }

    function testSubmitRevertsForMulticallSelector() public {
        bytes[] memory inner = new bytes[](1);
        inner[0] = abi.encodeCall(MockHub.doSomething, (42));
        bytes memory multicallData = abi.encodeWithSignature("multicall(bytes[])", inner);

        vm.expectRevert(ISupervisor.MulticallForbidden.selector);
        vm.prank(operator);
        supervisor.submit(multicallData);
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
        hub = new MockHub(address(registry), makeAddr("gateway"));
        factory = new SupervisorFactory(IHub(address(hub)));
    }

    function testNewSupervisor() public {
        bytes4[] memory timelockSels = new bytes4[](1);
        timelockSels[0] = bytes4(0x12345678);

        SupervisorConfig memory config =
            SupervisorConfig(timelockSels, new bytes4[](0), 1 days, 7 days, IManifest(address(0)));
        ISupervisor supervisor = factory.newSupervisor(POOL, makeAddr("operator"), config);

        assertEq(address(supervisor.hub()), address(hub));
        assertEq(PoolId.unwrap(supervisor.poolId()), PoolId.unwrap(POOL));
        assertEq(supervisor.timelock(), 1 days);
        assertEq(supervisor.expiryWindow(), 7 days);
        assertTrue(supervisor.timelocked(bytes4(0x12345678)));
    }
}
