// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {Envoy} from "../../../src/core/utils/Envoy.sol";
import {PoolId} from "../../../src/core/types/PoolId.sol";
import {IEnvoy} from "../../../src/core/utils/interfaces/IEnvoy.sol";
import {IManagerCallFromHub, IManagerCallFromSpoke} from "../../../src/core/utils/interfaces/IManagerCall.sol";

import "forge-std/Test.sol";

/// @notice Target implementing BOTH directions, recording the last call, its value, and which method ran.
///         `fromHub` carries no origin args (the hub direction is already authorized); `fromSpoke` carries
///         and records `(centrifugeId, sender)` for the untrusted direction to validate.
contract MockManagerCallTarget is IManagerCallFromHub, IManagerCallFromSpoke {
    PoolId public lastPoolId;
    bytes public lastPayload;
    uint256 public lastValue;
    uint16 public lastCentrifugeId;
    bytes32 public lastSender;
    bool public lastWasSpoke;

    function fromHub(PoolId poolId, bytes calldata payload) external payable {
        lastPoolId = poolId;
        lastPayload = payload;
        lastValue = msg.value;
        lastWasSpoke = false;
    }

    function fromSpoke(PoolId poolId, bytes calldata payload, uint16 centrifugeId, bytes32 sender) external payable {
        lastPoolId = poolId;
        lastPayload = payload;
        lastValue = msg.value;
        lastCentrifugeId = centrifugeId;
        lastSender = sender;
        lastWasSpoke = true;
    }
}

/// @notice Hub-only target implementing `fromHub` ONLY (no `fromSpoke`). Models every hub-only target
///         (BRM, Supervisor, NAVManager, OracleValuation): the spoke direction lands on a nonexistent
///         selector and reverts. This is the structural direction boundary.
contract MockHubOnlyTarget is IManagerCallFromHub {
    bool public called;

    function fromHub(PoolId, bytes calldata) external payable {
        called = true;
    }
}

contract EnvoyTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    address immutable AUTH = makeAddr("auth");
    address immutable ANY = makeAddr("any");

    Envoy dispatcher;
    MockManagerCallTarget target;

    function setUp() public {
        dispatcher = new Envoy(AUTH);
        target = new MockManagerCallTarget();
    }

    function testCallFromHubOnlyAuth() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.callFromHub(POOL_A, address(target), hex"1234");
    }

    function testCallFromHubForwardsAndEmits() public {
        bytes memory payload = hex"deadbeef";

        vm.expectEmit();
        emit IEnvoy.ManagerCallFromHub(POOL_A, address(target), payload);

        vm.deal(AUTH, 1 ether);
        vm.prank(AUTH);
        dispatcher.callFromHub{value: 0.7 ether}(POOL_A, address(target), payload);

        assertEq(PoolId.unwrap(target.lastPoolId()), PoolId.unwrap(POOL_A));
        assertEq(target.lastPayload(), payload);
        assertEq(target.lastValue(), 0.7 ether, "full value forwarded to target");
        assertFalse(target.lastWasSpoke(), "hub direction invokes fromHub");
    }

    function testCallFromSpokeForwardsAndEmits() public {
        bytes memory payload = hex"c0ffee";
        bytes32 sender = bytes32(uint256(uint160(makeAddr("spokeSender"))));

        vm.expectEmit();
        emit IEnvoy.ManagerCallFromSpoke(POOL_A, address(target), payload, 7, sender);

        vm.deal(AUTH, 1 ether);
        vm.prank(AUTH);
        dispatcher.callFromSpoke{value: 0.3 ether}(POOL_A, address(target), payload, 7, sender);

        assertEq(PoolId.unwrap(target.lastPoolId()), PoolId.unwrap(POOL_A));
        assertEq(target.lastPayload(), payload);
        assertEq(target.lastValue(), 0.3 ether, "full value forwarded to target");
        assertEq(target.lastCentrifugeId(), 7);
        assertEq(target.lastSender(), sender);
        assertTrue(target.lastWasSpoke(), "spoke direction invokes fromSpoke");
    }

    function testCallFromSpokeOnlyAuth() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        dispatcher.callFromSpoke(POOL_A, address(target), hex"1234", 2, bytes32(0));
    }

    /// @dev The direction boundary: a hub-only target (implements `fromHub` only) is physically unreachable
    ///      from the spoke direction because `callFromSpoke` invokes the nonexistent `fromSpoke` selector and
    ///      reverts. Distinct method names = distinct selectors is the structural guard that keeps the
    ///      spoke path off hub-only targets that never consult the policy.
    function testCallFromSpokeToHubOnlyTargetReverts() public {
        MockHubOnlyTarget hubOnly = new MockHubOnlyTarget();
        bytes memory payload = hex"abcd";
        bytes32 sender = bytes32(uint256(uint160(makeAddr("spokeSender"))));

        vm.prank(AUTH);
        vm.expectRevert();
        dispatcher.callFromSpoke(POOL_A, address(hubOnly), payload, 9, sender);

        assertFalse(hubOnly.called(), "spoke direction never lands on the hub-only target");

        // The same target IS reachable from the hub direction.
        vm.prank(AUTH);
        dispatcher.callFromHub(POOL_A, address(hubOnly), payload);
        assertTrue(hubOnly.called(), "hub direction reaches the hub-only target");
    }
}
