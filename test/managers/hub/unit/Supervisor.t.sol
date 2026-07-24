// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IManagerCallFromSpoke} from "../../../../src/core/utils/interfaces/IManagerCall.sol";

import {Supervisor, SupervisorFactory} from "../../../../src/managers/hub/Supervisor.sol";
import {ISupervisor, ISupervisorFactory, TrustedCall} from "../../../../src/managers/hub/interfaces/ISupervisor.sol";

import "forge-std/Test.sol";

/// @dev Records the last cancelAuthorization the Supervisor routed through the registry.
contract MockHubRegistry {
    bytes public lastCancelled;

    function cancelAuthorization(PoolId, address, bytes calldata data) external {
        lastCancelled = data;
    }
}

contract MockHub {
    IHubRegistry public immutable hubRegistry;

    constructor(IHubRegistry hubRegistry_) {
        hubRegistry = hubRegistry_;
    }

    function cancelAuthorization(PoolId poolId, bytes calldata data) external {
        hubRegistry.cancelAuthorization(poolId, msg.sender, data);
    }
}

contract SupervisorTest is Test {
    using CastLib for address;

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16(uint128(2)));

    address immutable envoy = makeAddr("envoy");
    address immutable sentinelA = makeAddr("sentinelA");
    address immutable sentinelB = makeAddr("sentinelB");
    address immutable outsider = makeAddr("outsider");

    MockHubRegistry registry = new MockHubRegistry();
    MockHub mockHub = new MockHub(IHubRegistry(address(registry)));
    Supervisor supervisor;

    bytes4 constant UPDATE_SHARE_PRICE_WITH_TIMESTAMP =
        bytes4(keccak256("updateSharePrice(uint64,bytes16,uint128,uint64)"));
    bytes data = abi.encodeWithSelector(UPDATE_SHARE_PRICE_WITH_TIMESTAMP, POOL_A, SC_A, uint256(1e18), uint64(1));

    function setUp() public {
        supervisor = new Supervisor(IHub(address(mockHub)), POOL_A, envoy);
    }

    function _addSentinel(address s) internal {
        vm.prank(envoy);
        supervisor.fromHub(POOL_A, abi.encode(TrustedCall.AddSentinel, s));
    }

    function _removeSentinelCall(address s) internal view returns (bytes memory) {
        bytes memory inner = abi.encode(TrustedCall.RemoveSentinel, s);
        return abi.encodeWithSelector(
            IHub.managerCall.selector,
            POOL_A,
            uint16(1),
            address(supervisor).toBytes32(),
            inner,
            uint128(0),
            uint256(0),
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

    function testSentinelCanCancelOtherTargetSharingRemoveSentinelShape() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        // A managerCall targeting a different contract (e.g. AdapterFailover.UpdateSteward) can encode a
        // payload with the same leading-word/address-at-44 shape as RemoveSentinel(sentinelA): first word
        // 1, address at offset 44. Without pinning the target to this Supervisor, this would be
        // misclassified as sentinelA's own removal and block the veto.
        address other = makeAddr("adapterFailover");
        bytes memory inner = abi.encode(uint8(1), sentinelA, true);
        bytes memory call = abi.encodeWithSelector(
            IHub.managerCall.selector, POOL_A, uint16(1), other.toBytes32(), inner, uint128(0), uint256(0), address(0)
        );

        vm.prank(sentinelA);
        supervisor.cancelAuthorization(call);
        assertEq(registry.lastCancelled(), call);
    }

    function testSentinelVetoNotBlockedByMalformedPayload() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        // A compromised manager could authorize an out-of-policy managerCall whose inner payload is
        // shaped so a strict (TrustedCall, address) decode reverts (here: a 64-byte payload whose first
        // word is out of enum range). The self-removal guard must tolerate it, not revert, or it would
        // freeze the sentinel veto for exactly such calls.
        bytes memory malformed = abi.encode(type(uint256).max, type(uint256).max);
        bytes memory call = abi.encodeWithSelector(
            IHub.managerCall.selector,
            POOL_A,
            uint16(1),
            address(supervisor).toBytes32(),
            malformed,
            uint128(0),
            uint256(0),
            address(0)
        );

        vm.prank(sentinelA);
        supervisor.cancelAuthorization(call);
        assertEq(registry.lastCancelled(), call);
    }

    function testSentinelVetoNotBlockedByTruncatedManagerCallArgs() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        // A managerCall selector with fewer than the 224 static-encoded bytes of its args would revert an
        // unguarded abi.decode. The self-removal guard must tolerate it, not revert, or it would freeze
        // the sentinel veto for exactly such calls.
        bytes memory call = abi.encodeWithSelector(IHub.managerCall.selector, POOL_A, uint16(1));

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

    function testAddSentinelAlreadySentinel() public {
        _addSentinel(sentinelA);

        vm.expectRevert(ISupervisor.AlreadySentinel.selector);
        vm.prank(envoy);
        supervisor.fromHub(POOL_A, abi.encode(TrustedCall.AddSentinel, sentinelA));
    }

    /// @dev Documents the accepted bootstrap gap: the very first AddSentinel authorization for a freshly
    ///      deployed Supervisor matures with no possible veto, since no sentinel exists yet to call
    ///      cancelAuthorization. Reviewed this session and accepted as an operational deployment concern
    ///      (seed the first sentinel promptly), not a code fix — this test pins the current behavior.
    function testFirstAddSentinelHasNoVetoWindow() public {
        assertEq(supervisor.sentinelCount(), 0);

        // No sentinel exists, so cancelAuthorization would revert NotSentinel for anyone who tried.
        vm.expectRevert(ISupervisor.NotSentinel.selector);
        vm.prank(outsider);
        supervisor.cancelAuthorization(_removeSentinelCall(sentinelA));

        // The first AddSentinel still matures and executes normally.
        _addSentinel(sentinelA);
        assertTrue(supervisor.sentinels(sentinelA));
        assertEq(supervisor.sentinelCount(), 1);
    }

    function testAddSentinelOnlyEnvoy() public {
        vm.expectRevert(ISupervisor.NotEnvoy.selector);
        supervisor.fromHub(POOL_A, abi.encode(TrustedCall.AddSentinel, sentinelA));
    }

    function testFromHubRejectsValue() public {
        vm.deal(envoy, 1 ether);
        vm.expectRevert(ISupervisor.UnexpectedValue.selector);
        vm.prank(envoy);
        supervisor.fromHub{value: 1 ether}(POOL_A, abi.encode(TrustedCall.AddSentinel, sentinelA));
    }

    function testAddSentinelZeroAddress() public {
        vm.expectRevert(ISupervisor.ZeroAddress.selector);
        vm.prank(envoy);
        supervisor.fromHub(POOL_A, abi.encode(TrustedCall.AddSentinel, address(0)));
    }

    function testRemoveSentinel() public {
        _addSentinel(sentinelA);
        _addSentinel(sentinelB);

        vm.expectEmit();
        emit ISupervisor.RemoveSentinel(sentinelA);
        vm.prank(envoy);
        supervisor.fromHub(POOL_A, abi.encode(TrustedCall.RemoveSentinel, sentinelA));

        assertFalse(supervisor.sentinels(sentinelA));
        assertEq(supervisor.sentinelCount(), 1);
    }

    function testCannotRemoveLastSentinel() public {
        _addSentinel(sentinelA);

        vm.expectRevert(ISupervisor.LastSentinel.selector);
        vm.prank(envoy);
        supervisor.fromHub(POOL_A, abi.encode(TrustedCall.RemoveSentinel, sentinelA));
    }

    function testFromHubWrongPoolReverts() public {
        // A managerCall from another pool routed at this Supervisor must be rejected.
        vm.expectRevert(ISupervisor.NotPool.selector);
        vm.prank(envoy);
        supervisor.fromHub(PoolId.wrap(999), abi.encode(TrustedCall.AddSentinel, sentinelA));
    }

    /// @dev Direction boundary: the Supervisor is a hub-only target — it implements
    ///      `IManagerCallFromHub.fromHub` ONLY, never `IManagerCallFromSpoke.fromSpoke`. So the untrusted
    ///      spoke path (`Envoy.callFromSpoke` -> `target.fromSpoke`) can never reach it (nonexistent
    ///      selector). Freezes the guarantee on the real contract; adding `fromSpoke` later trips this.
    function testFromSpokeUnreachable() public {
        vm.prank(envoy);
        vm.expectRevert();
        IManagerCallFromSpoke(address(supervisor))
            .fromSpoke(POOL_A, abi.encode(TrustedCall.AddSentinel, sentinelA), 0, bytes32(0));
    }

    // ─── factory ────────────────────────────────────────────────────────────────

    function testFactoryDeploys() public {
        SupervisorFactory factory = new SupervisorFactory(IHub(address(mockHub)));

        vm.expectEmit(true, false, false, false);
        emit ISupervisorFactory.DeploySupervisor(POOL_A, address(0));
        ISupervisor s = factory.newSupervisor(POOL_A, envoy);

        assertEq(address(s.hub()), address(mockHub));
        assertEq(s.envoy(), envoy);
    }

    function testFactoryPreviewMatchesDeploy() public {
        SupervisorFactory factory = new SupervisorFactory(IHub(address(mockHub)));

        address predicted = factory.previewSupervisor(POOL_A, envoy);
        ISupervisor s = factory.newSupervisor(POOL_A, envoy);
        assertEq(address(s), predicted);
    }
}
