// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifest, SupervisorConfig} from
    "../../../../src/managers/hub/interfaces/ISupervisor.sol";
import {Supervisor, SupervisorFactory} from "../../../../src/managers/hub/Supervisor.sol";

import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IERC7751} from "../../../../src/misc/interfaces/IERC7751.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";

import "forge-std/Test.sol";

// ─── Mock contracts ─────────────────────────────────────────────────────────

contract MockHub {
    address public hubRegistry_;
    uint256 public lastValue;

    constructor(address hubRegistry) {
        hubRegistry_ = hubRegistry;
    }

    function hubRegistry() external view returns (IHubRegistry) {
        return IHubRegistry(hubRegistry_);
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

    address manager = makeAddr("manager");
    address sentinel = makeAddr("sentinel");
    address unauthorized = makeAddr("unauthorized");

    bytes4 constant TIMELOCKED_SEL = MockHub.timelocked.selector;
    bytes4 constant HOOKED_SEL = MockHub.hookedFn.selector;

    uint48 constant DELAY = 2 days;
    uint48 constant EXPIRY = 7 days;

    function _deploySupervisor(IManifest hook) internal returns (Supervisor) {
        bytes4[] memory timelockSels = new bytes4[](1);
        timelockSels[0] = TIMELOCKED_SEL;

        bytes4[] memory hookSels = new bytes4[](1);
        hookSels[0] = HOOKED_SEL;

        SupervisorConfig memory config =
            SupervisorConfig(timelockSels, hookSels, DELAY, EXPIRY, hook);

        return new Supervisor(IHub(address(hub)), POOL, config);
    }

    function setUp() public virtual {
        registry = new MockHubRegistry();
        hub = new MockHub(address(registry));
        registry.setManager(POOL, manager, true);
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

        vm.prank(manager);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testExecuteForwardsValue() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (99));

        vm.deal(manager, 1 ether);
        vm.prank(manager);
        supervisor.execute{value: 0.5 ether}(data);

        assertEq(hub.lastValue(), 99);
        assertEq(address(hub).balance, 0.5 ether);
    }

    function testExecuteRevertsForNonManager() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.expectRevert(ISupervisor.NotManager.selector);
        vm.prank(unauthorized);
        supervisor.execute(data);
    }

    function testExecuteWrapsHubRevert() public {
        bytes memory data = abi.encodeCall(MockHub.alwaysReverts, ());

        vm.expectRevert();
        vm.prank(manager);
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
        vm.prank(manager);
        supervisor.execute(data);
    }

    function testTimelockFullFlow() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        // Too early
        vm.expectRevert();
        vm.prank(manager);
        supervisor.execute(data);

        // After delay
        vm.warp(block.timestamp + DELAY);
        vm.prank(manager);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testTimelockExpires() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.warp(block.timestamp + DELAY + EXPIRY + 1);

        vm.expectRevert(ISupervisor.TimelockExpired.selector);
        vm.prank(manager);
        supervisor.execute(data);
    }

    function testTimelockCannotSubmitTwice() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.OperationAlreadyPending.selector);
        vm.prank(manager);
        supervisor.submit(data);
    }

    function testTimelockCannotReplay() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.warp(block.timestamp + DELAY);
        vm.prank(manager);
        supervisor.execute(data);

        // Second execute should fail
        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.execute(data);
    }

    function testSubmitRevertsForNonTimelocked() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.expectRevert(ISupervisor.TimelockNotSet.selector);
        vm.prank(manager);
        supervisor.submit(data);
    }

    function testSubmitRevertsForNonManager() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.expectRevert(ISupervisor.NotManager.selector);
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
        vm.prank(manager);
        supervisor.addSentinel(sentinel);
    }

    function testManagerCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.prank(manager);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }

    function testSentinelCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.prank(sentinel);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }

    function testUnauthorizedCannotCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.NotManagerOrSentinel.selector);
        vm.prank(unauthorized);
        supervisor.cancel(data);
    }

    function testCannotCancelNonPending() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (99));

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.cancel(data);
    }

    function testCancelPreventsExecution() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.prank(sentinel);
        supervisor.cancel(data);

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.execute(data);
    }

    function testSentinelCannotCancelOwnRemovalWithMultipleSentinels() public {
        address sentinel2 = makeAddr("sentinel2");
        vm.prank(manager);
        supervisor.addSentinel(sentinel2);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(manager);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.CannotSelfCancel.selector);
        vm.prank(sentinel);
        supervisor.cancel(data);
    }

    function testSoleSentinelCanCancelOwnRemoval() public {
        // Only one sentinel set (from setUp)
        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(manager);
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

        vm.prank(manager);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testHookBlocksWhenReverting() public {
        hook.setShouldRevert(true);
        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.expectRevert(MockManifest.Blocked.selector);
        vm.prank(manager);
        supervisor.execute(data);
    }

    function testHookAllowsWhenPassing() public {
        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.prank(manager);
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

    function testAddSentinel() public {
        vm.prank(manager);
        supervisor.addSentinel(sentinel);

        assertTrue(supervisor.sentinels(sentinel));
    }

    function testAddSentinelRevertsForNonManager() public {
        vm.expectRevert(ISupervisor.NotManager.selector);
        vm.prank(unauthorized);
        supervisor.addSentinel(sentinel);
    }

    function testAddSentinelRevertsForZeroAddress() public {
        vm.expectRevert(ISupervisor.ZeroAddress.selector);
        vm.prank(manager);
        supervisor.addSentinel(address(0));
    }

    function testAddSentinelRevertsIfAlreadySentinel() public {
        vm.prank(manager);
        supervisor.addSentinel(sentinel);

        vm.expectRevert(ISupervisor.AlreadySentinel.selector);
        vm.prank(manager);
        supervisor.addSentinel(sentinel);
    }

    function testRemoveSentinelRequiresTimelock() public {
        vm.prank(manager);
        supervisor.addSentinel(sentinel);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.removeSentinel(sentinel);
    }

    function testRemoveSentinelFullFlow() public {
        vm.prank(manager);
        supervisor.addSentinel(sentinel);

        // Submit the removeSentinel call
        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(manager);
        supervisor.submit(data);

        // Wait for delay
        vm.warp(block.timestamp + DELAY);

        // Execute
        vm.prank(manager);
        supervisor.removeSentinel(sentinel);

        assertFalse(supervisor.sentinels(sentinel));
    }

    function testRemoveSentinelTooEarly() public {
        vm.prank(manager);
        supervisor.addSentinel(sentinel);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(manager);
        supervisor.submit(data);

        // Try to execute before delay
        vm.expectRevert();
        vm.prank(manager);
        supervisor.removeSentinel(sentinel);

        // Still a sentinel
        assertTrue(supervisor.sentinels(sentinel));
    }

    function testSoleSentinelCanVetoOwnRemoval() public {
        vm.prank(manager);
        supervisor.addSentinel(sentinel);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(manager);
        supervisor.submit(data);

        // Sole sentinel vetoes
        vm.prank(sentinel);
        supervisor.cancel(data);

        // Now removal fails
        vm.warp(block.timestamp + DELAY);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.removeSentinel(sentinel);

        // Still a sentinel
        assertTrue(supervisor.sentinels(sentinel));
    }

    function testOtherSentinelCanVetoRemoval() public {
        vm.prank(manager);
        supervisor.addSentinel(sentinel);

        address sentinel2 = makeAddr("sentinel2");
        vm.prank(manager);
        supervisor.addSentinel(sentinel2);

        bytes memory data = abi.encodeCall(Supervisor.removeSentinel, (sentinel));
        vm.prank(manager);
        supervisor.submit(data);

        // Other sentinel vetoes (not the one being removed)
        vm.prank(sentinel2);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
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
        hub = new MockHub(address(registry));
        factory = new SupervisorFactory(IHub(address(hub)));
    }

    function testNewSupervisor() public {
        bytes4[] memory timelockSels = new bytes4[](1);
        timelockSels[0] = bytes4(0x12345678);

        SupervisorConfig memory config =
            SupervisorConfig(timelockSels, new bytes4[](0), 1 days, 7 days, IManifest(address(0)));
        ISupervisor supervisor = factory.newSupervisor(POOL, config);

        assertEq(address(supervisor.hub()), address(hub));
        assertEq(PoolId.unwrap(supervisor.poolId()), PoolId.unwrap(POOL));
        assertEq(supervisor.delay(), 1 days);
        assertEq(supervisor.expiryWindow(), 7 days);
        assertTrue(supervisor.timelocked(bytes4(0x12345678)));
    }
}
