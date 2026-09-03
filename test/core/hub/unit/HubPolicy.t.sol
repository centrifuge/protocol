// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Hub} from "../../../../src/core/hub/Hub.sol";
import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IHubPolicy} from "../../../../src/core/utils/interfaces/IPolicy.sol";
import {IAccounting} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IMultiAdapter} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

/// @dev Records the last enforce() call and can be toggled to revert (out of policy / forbidden).
contract MockPolicy is IHubPolicy {
    error Unauthorized();

    PoolId public lastPoolId;
    address public lastCaller;
    bytes public lastData;
    uint256 public enforceCalls;
    bool public shouldRevert;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function authorizationDelay(PoolId, address, bytes calldata) external pure returns (uint48) {
        return 0;
    }

    function enforce(PoolId poolId, address caller, bytes calldata data) external {
        enforceCalls++;
        lastPoolId = poolId;
        lastCaller = caller;
        lastData = data;
        if (shouldRevert) revert Unauthorized();
    }
}

contract HubPolicyTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    address immutable manager = makeAddr("manager");

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));

    Hub hub = new Hub(gateway, holdings, accounting, hubRegistry, multiAdapter, scm, address(this));
    MockPolicy policy = new MockPolicy();

    bytes metadata = "meta";

    function setUp() public {
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, manager),
            abi.encode(true)
        );
        vm.mockCall(address(hubRegistry), abi.encodeWithSelector(hubRegistry.setMetadata.selector), abi.encode());
        // Policy storage now lives in the registry; the Hub reads/writes through it.
        vm.mockCall(address(hubRegistry), abi.encodeWithSelector(IHubRegistry.setPolicy.selector), abi.encode());
        _installPolicy(IHubPolicy(address(0))); // default: no policy installed
    }

    /// @dev Mock the registry to report `policy_` as the pool's installed policy (Hub reads through to it).
    function _installPolicy(IHubPolicy policy_) internal {
        vm.mockCall(
            address(hubRegistry), abi.encodeWithSelector(IHubRegistry.policy.selector, POOL_A), abi.encode(policy_)
        );
    }

    // ─── setPolicy ──────────────────────────────────────────────────────────

    function testSetPolicyByWardWritesThroughToRegistry() public {
        // Ward (this) installs directly; the Hub persists the policy in the registry.
        vm.expectCall(address(hubRegistry), abi.encodeCall(IHubRegistry.setPolicy, (POOL_A, policy)));
        hub.setPolicy(POOL_A, policy);

        // The Hub's view reads back through the registry.
        _installPolicy(policy);
        assertEq(address(hub.policy(POOL_A)), address(policy));
    }

    function testSetPolicyByNonManagerNonWardReverts() public {
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, address(0xBAD)),
            abi.encode(false)
        );
        vm.expectRevert(IHub.NotManager.selector);
        vm.prank(address(0xBAD));
        hub.setPolicy(POOL_A, policy);
    }

    function testSetPolicyByManagerEnforcesCurrentPolicy() public {
        _installPolicy(policy); // current policy installed

        // A manager replacing the policy is enforced by the current policy.
        policy.setShouldRevert(true);
        vm.expectRevert(MockPolicy.Unauthorized.selector);
        vm.prank(manager);
        hub.setPolicy(POOL_A, policy);

        // When the current policy allows it, the replacement is written through to the registry.
        policy.setShouldRevert(false);
        MockPolicy next = new MockPolicy();
        vm.expectCall(address(hubRegistry), abi.encodeCall(IHubRegistry.setPolicy, (POOL_A, next)));
        vm.prank(manager);
        hub.setPolicy(POOL_A, next);
    }

    // ─── enforcement on manager methods ─────────────────────────────────────────

    function testNoPolicySkipsEnforcement() public {
        // No policy installed: only the manager check applies.
        vm.prank(manager);
        hub.setPoolMetadata(POOL_A, metadata);
        assertEq(policy.enforceCalls(), 0);
    }

    function testPolicyEnforcedOnManagerMethod() public {
        _installPolicy(policy);

        vm.prank(manager);
        hub.setPoolMetadata(POOL_A, metadata);

        assertEq(policy.enforceCalls(), 1);
        assertEq(policy.lastCaller(), manager);
        // The policy receives the exact call's calldata (selector + args).
        assertEq(policy.lastData(), abi.encodeWithSelector(IHub.setPoolMetadata.selector, POOL_A, metadata));
    }

    function testManagerMethodRevertsWhenPolicyReverts() public {
        _installPolicy(policy);
        policy.setShouldRevert(true);

        vm.expectRevert(MockPolicy.Unauthorized.selector);
        vm.prank(manager);
        hub.setPoolMetadata(POOL_A, metadata);
    }

    function testManagerCheckPrecedesPolicy() public {
        _installPolicy(policy);
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, address(0xBAD)),
            abi.encode(false)
        );

        // Non-manager is rejected before the policy is consulted.
        vm.expectRevert(IHub.NotManager.selector);
        vm.prank(address(0xBAD));
        hub.setPoolMetadata(POOL_A, metadata);
        assertEq(policy.enforceCalls(), 0);
    }
}
