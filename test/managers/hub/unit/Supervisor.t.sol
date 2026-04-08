// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifest} from "../../../../src/managers/hub/interfaces/ISupervisor.sol";
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
    address guardian = makeAddr("guardian");
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

        return new Supervisor(IHub(address(hub)), POOL, timelockSels, hookSels, DELAY, EXPIRY, hook);
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
        supervisor.addGuardian(guardian);
    }

    function testManagerCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.prank(manager);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }

    function testGuardianCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.prank(guardian);
        supervisor.cancel(data);

        assertEq(supervisor.pending(data), 0);
    }

    function testUnauthorizedCannotCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.NotManagerOrGuardian.selector);
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

        vm.prank(guardian);
        supervisor.cancel(data);

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.execute(data);
    }

    function testGuardianCannotCancelOwnRemovalWithMultipleGuardians() public {
        address guardian2 = makeAddr("guardian2");
        vm.prank(manager);
        supervisor.addGuardian(guardian2);

        bytes memory data = abi.encodeCall(Supervisor.removeGuardian, (guardian));
        vm.prank(manager);
        supervisor.submit(data);

        vm.expectRevert(ISupervisor.CannotSelfCancel.selector);
        vm.prank(guardian);
        supervisor.cancel(data);
    }

    function testSoleGuardianCanCancelOwnRemoval() public {
        // Only one guardian set (from setUp)
        bytes memory data = abi.encodeCall(Supervisor.removeGuardian, (guardian));
        vm.prank(manager);
        supervisor.submit(data);

        vm.prank(guardian);
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

// ─── Guardian management ────────────────────────────────────────────────────

contract SupervisorGuardianTest is SupervisorTestBase {
    Supervisor supervisor;

    function setUp() public override {
        super.setUp();
        supervisor = _deploySupervisor(IManifest(address(0)));
    }

    function testAddGuardian() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        assertTrue(supervisor.guardians(guardian));
    }

    function testAddGuardianRevertsForNonManager() public {
        vm.expectRevert(ISupervisor.NotManager.selector);
        vm.prank(unauthorized);
        supervisor.addGuardian(guardian);
    }

    function testAddGuardianRevertsForZeroAddress() public {
        vm.expectRevert(ISupervisor.ZeroAddress.selector);
        vm.prank(manager);
        supervisor.addGuardian(address(0));
    }

    function testAddGuardianRevertsIfAlreadyGuardian() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        vm.expectRevert(ISupervisor.AlreadyGuardian.selector);
        vm.prank(manager);
        supervisor.addGuardian(guardian);
    }

    function testRemoveGuardianRequiresTimelock() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.removeGuardian(guardian);
    }

    function testRemoveGuardianFullFlow() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        // Submit the removeGuardian call
        bytes memory data = abi.encodeCall(Supervisor.removeGuardian, (guardian));
        vm.prank(manager);
        supervisor.submit(data);

        // Wait for delay
        vm.warp(block.timestamp + DELAY);

        // Execute
        vm.prank(manager);
        supervisor.removeGuardian(guardian);

        assertFalse(supervisor.guardians(guardian));
    }

    function testRemoveGuardianTooEarly() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        bytes memory data = abi.encodeCall(Supervisor.removeGuardian, (guardian));
        vm.prank(manager);
        supervisor.submit(data);

        // Try to execute before delay
        vm.expectRevert();
        vm.prank(manager);
        supervisor.removeGuardian(guardian);

        // Still a guardian
        assertTrue(supervisor.guardians(guardian));
    }

    function testSoleGuardianCanVetoOwnRemoval() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        bytes memory data = abi.encodeCall(Supervisor.removeGuardian, (guardian));
        vm.prank(manager);
        supervisor.submit(data);

        // Sole guardian vetoes
        vm.prank(guardian);
        supervisor.cancel(data);

        // Now removal fails
        vm.warp(block.timestamp + DELAY);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.removeGuardian(guardian);

        // Still a guardian
        assertTrue(supervisor.guardians(guardian));
    }

    function testOtherGuardianCanVetoRemoval() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        address guardian2 = makeAddr("guardian2");
        vm.prank(manager);
        supervisor.addGuardian(guardian2);

        bytes memory data = abi.encodeCall(Supervisor.removeGuardian, (guardian));
        vm.prank(manager);
        supervisor.submit(data);

        // Other guardian vetoes (not the one being removed)
        vm.prank(guardian2);
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

        ISupervisor supervisor =
            factory.newSupervisor(POOL, timelockSels, new bytes4[](0), 1 days, 7 days, IManifest(address(0)));

        assertEq(address(supervisor.hub()), address(hub));
        assertEq(PoolId.unwrap(supervisor.poolId()), PoolId.unwrap(POOL));
        assertEq(supervisor.delay(), 1 days);
        assertEq(supervisor.expiryWindow(), 7 days);
        assertTrue(supervisor.timelocked(bytes4(0x12345678)));
    }
}
