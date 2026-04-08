// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISupervisor, ISupervisorFactory, IManifestHook} from "../../../../src/managers/hub/interfaces/ISupervisor.sol";
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

contract MockManifestHook is IManifestHook {
    bool public shouldPass = true;

    function setShouldPass(bool v) external {
        shouldPass = v;
    }

    function check(PoolId, address, bytes calldata) external returns (bool) {
        return shouldPass;
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

    function _deploySupervisor(IManifestHook hook) internal returns (Supervisor) {
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
        supervisor = _deploySupervisor(IManifestHook(address(0)));
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
        supervisor = _deploySupervisor(IManifestHook(address(0)));
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
        supervisor = _deploySupervisor(IManifestHook(address(0)));
        vm.prank(manager);
        supervisor.addGuardian(guardian);
    }

    function testManagerCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        bytes32 operationId = keccak256(data);

        vm.prank(manager);
        supervisor.cancel(operationId);

        assertEq(supervisor.pending(operationId), 0);
    }

    function testGuardianCanCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        bytes32 operationId = keccak256(data);

        vm.prank(guardian);
        supervisor.cancel(operationId);

        assertEq(supervisor.pending(operationId), 0);
    }

    function testUnauthorizedCannotCancel() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        bytes32 operationId = keccak256(data);

        vm.expectRevert(ISupervisor.NotManagerOrGuardian.selector);
        vm.prank(unauthorized);
        supervisor.cancel(operationId);
    }

    function testCannotCancelNonPending() public {
        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.cancel(bytes32(uint256(1)));
    }

    function testCancelPreventsExecution() public {
        bytes memory data = abi.encodeCall(MockHub.timelocked, (42));

        vm.prank(manager);
        supervisor.submit(data);

        vm.prank(guardian);
        supervisor.cancel(keccak256(data));

        vm.warp(block.timestamp + DELAY);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.execute(data);
    }
}

// ─── Manifest hook ──────────────────────────────────────────────────────────

contract SupervisorManifestHookTest is SupervisorTestBase {
    Supervisor supervisor;
    MockManifestHook hook;

    function setUp() public override {
        super.setUp();
        hook = new MockManifestHook();
        supervisor = _deploySupervisor(IManifestHook(address(hook)));
    }

    function testHookPassesForNonHookedSelector() public {
        bytes memory data = abi.encodeCall(MockHub.doSomething, (42));

        vm.prank(manager);
        supervisor.execute(data);

        assertEq(hub.lastValue(), 42);
    }

    function testHookBlocksWhenFalse() public {
        hook.setShouldPass(false);
        bytes memory data = abi.encodeCall(MockHub.hookedFn, (42));

        vm.expectRevert(ISupervisor.ManifestCheckFailed.selector);
        vm.prank(manager);
        supervisor.execute(data);
    }

    function testHookAllowsWhenTrue() public {
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
        supervisor = _deploySupervisor(IManifestHook(address(0)));
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

    function testGuardianCanVetoOwnRemoval() public {
        vm.prank(manager);
        supervisor.addGuardian(guardian);

        bytes memory data = abi.encodeCall(Supervisor.removeGuardian, (guardian));
        vm.prank(manager);
        supervisor.submit(data);

        // Guardian vetoes
        vm.prank(guardian);
        supervisor.cancel(keccak256(data));

        // Now removal fails
        vm.warp(block.timestamp + DELAY);

        vm.expectRevert(ISupervisor.OperationNotPending.selector);
        vm.prank(manager);
        supervisor.removeGuardian(guardian);

        // Still a guardian
        assertTrue(supervisor.guardians(guardian));
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
            factory.newSupervisor(POOL, timelockSels, new bytes4[](0), 1 days, 7 days, IManifestHook(address(0)));

        assertEq(address(supervisor.hub()), address(hub));
        assertEq(PoolId.unwrap(supervisor.poolId()), PoolId.unwrap(POOL));
        assertEq(supervisor.delay(), 1 days);
        assertEq(supervisor.expiryWindow(), 7 days);
        assertTrue(supervisor.timelocked(bytes4(0x12345678)));
    }
}
