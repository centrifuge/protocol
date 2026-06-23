// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";

import {Supervisor, SupervisorFactory} from "../../../../src/managers/hub/Supervisor.sol";
import {ISupervisor, ISupervisorFactory, TrustedCall} from "../../../../src/managers/hub/interfaces/ISupervisor.sol";

import "forge-std/Test.sol";

/// @dev Records the last cancelAuthorization the Supervisor routed through the registry.
contract MockHubRegistry {
    bytes public lastCancelled;

    function cancelAuthorization(PoolId, bytes calldata data) external {
        lastCancelled = data;
    }
}

contract MockHub {
    IHubRegistry public immutable hubRegistry;

    constructor(IHubRegistry hubRegistry_) {
        hubRegistry = hubRegistry_;
    }
}

contract SupervisorTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));

    address immutable contractUpdater = makeAddr("contractUpdater");
    address immutable sentinelA = makeAddr("sentinelA");
    address immutable sentinelB = makeAddr("sentinelB");
    address immutable outsider = makeAddr("outsider");

    MockHubRegistry registry = new MockHubRegistry();
    MockHub mockHub = new MockHub(IHubRegistry(address(registry)));
    Supervisor supervisor;

    bytes data = abi.encodeWithSelector(IHub.updateSharePrice.selector, POOL_A, SC_A, uint256(1e18), uint64(1));

    function setUp() public {
        supervisor = new Supervisor(IHub(address(mockHub)), POOL_A, contractUpdater);
    }

    function _addSentinel(address s) internal {
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL_A, SC_A, abi.encode(TrustedCall.AddSentinel, s));
    }

    function _removeSentinelCall(address s) internal view returns (bytes memory) {
        bytes memory inner = abi.encode(TrustedCall.RemoveSentinel, s);
        return abi.encodeWithSelector(
            IHub.updateContract.selector,
            POOL_A,
            SC_A,
            uint16(1),
            bytes32(bytes20(address(supervisor))),
            inner,
            uint128(0),
            address(0)
        );
    }

    // ─── cancelAuthorization ────────────────────────────────────────────────────

    function testSentinelCanCancel() public {
        _addSentinel(sentinelA);
        vm.prank(sentinelA);
        supervisor.cancelAuthorization(data);
        assertEq(registry.lastCancelled(), data);
    }

    function testNonSentinelCannotCancel() public {
        vm.expectRevert(ISupervisor.NotSentinel.selector);
        vm.prank(outsider);
        supervisor.cancelAuthorization(data);
    }

    function testSentinelCannotCancelOwnRemovalWithMultipleSentinels() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        vm.expectRevert(ISupervisor.CannotSelfCancel.selector);
        vm.prank(sentinelA);
        supervisor.cancelAuthorization(_removeSentinelCall(sentinelA));
    }

    function testSentinelCanCancelOtherSentinelRemoval() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        vm.prank(sentinelA);
        supervisor.cancelAuthorization(_removeSentinelCall(sentinelB));
        assertEq(registry.lastCancelled(), _removeSentinelCall(sentinelB));
    }

    function testSoleSentinelCanCancelOwnRemoval() public {
        _addSentinel(sentinelA); // only one sentinel -> guard skipped

        vm.prank(sentinelA);
        supervisor.cancelAuthorization(_removeSentinelCall(sentinelA));
        assertEq(registry.lastCancelled(), _removeSentinelCall(sentinelA));
    }

    function testSentinelVetoNotBlockedByMalformedPayload() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        // A compromised operator could authorize an out-of-policy updateContract whose inner payload
        // is shaped so a strict (TrustedCall, address) decode reverts (here: a 64-byte payload whose
        // first word is out of enum range). The self-removal guard must tolerate it, not revert, or it
        // would freeze the sentinel veto for exactly such calls.
        bytes memory malformed = abi.encode(type(uint256).max, type(uint256).max);
        bytes memory call = abi.encodeWithSelector(
            IHub.updateContract.selector,
            POOL_A,
            SC_A,
            uint16(1),
            bytes32(bytes20(address(supervisor))),
            malformed,
            uint128(0),
            address(0)
        );

        vm.prank(sentinelA);
        supervisor.cancelAuthorization(call);
        assertEq(registry.lastCancelled(), call);
    }

    // ─── sentinel management ────────────────────────────────────────────────────

    function testAddSentinel() public {
        vm.expectEmit();
        emit ISupervisor.AddSentinel(sentinelA);
        _addSentinel(sentinelA);

        assertTrue(supervisor.sentinels(sentinelA));
        assertEq(supervisor.sentinelCount(), 1);
    }

    function testAddSentinelOnlyContractUpdater() public {
        vm.expectRevert(ISupervisor.NotContractUpdater.selector);
        supervisor.trustedCall(POOL_A, SC_A, abi.encode(TrustedCall.AddSentinel, sentinelA));
    }

    function testAddSentinelZeroAddress() public {
        vm.expectRevert(ISupervisor.ZeroAddress.selector);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL_A, SC_A, abi.encode(TrustedCall.AddSentinel, address(0)));
    }

    function testRemoveSentinel() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        vm.expectEmit();
        emit ISupervisor.RemoveSentinel(sentinelA);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL_A, SC_A, abi.encode(TrustedCall.RemoveSentinel, sentinelA));

        assertFalse(supervisor.sentinels(sentinelA));
        assertEq(supervisor.sentinelCount(), 1);
    }

    function testCannotRemoveLastSentinel() public {
        _addSentinel(sentinelA);

        vm.expectRevert(ISupervisor.LastSentinel.selector);
        vm.prank(contractUpdater);
        supervisor.trustedCall(POOL_A, SC_A, abi.encode(TrustedCall.RemoveSentinel, sentinelA));
    }

    function testTrustedCallWrongPoolReverts() public {
        // An updateContract from another pool routed at this Supervisor must be rejected.
        vm.expectRevert(ISupervisor.NotPool.selector);
        vm.prank(contractUpdater);
        supervisor.trustedCall(PoolId.wrap(999), SC_A, abi.encode(TrustedCall.AddSentinel, sentinelA));
    }

    // ─── factory ────────────────────────────────────────────────────────────────

    function testFactoryDeploys() public {
        SupervisorFactory factory = new SupervisorFactory(IHub(address(mockHub)));

        vm.expectEmit(true, false, false, false);
        emit ISupervisorFactory.DeploySupervisor(POOL_A, address(0));
        ISupervisor s = factory.newSupervisor(POOL_A, contractUpdater);

        assertEq(address(s.hub()), address(mockHub));
        assertEq(s.contractUpdater(), contractUpdater);
    }

    function testFactoryPreviewMatchesDeploy() public {
        SupervisorFactory factory = new SupervisorFactory(IHub(address(mockHub)));

        address predicted = factory.previewSupervisor(POOL_A, contractUpdater);
        ISupervisor s = factory.newSupervisor(POOL_A, contractUpdater);
        assertEq(address(s), predicted);
    }
}
