// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {Hub} from "../../../../src/core/hub/Hub.sol";
import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {IHub} from "../../../../src/core/hub/interfaces/IHub.sol";
import {IHoldings} from "../../../../src/core/hub/interfaces/IHoldings.sol";
import {IManifest} from "../../../../src/core/hub/interfaces/IManifest.sol";
import {IAccounting} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IMultiAdapter} from "../../../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

/// @dev Records the last enforce() call and can be toggled to revert (out of policy / forbidden).
contract MockManifest is IManifest {
    PoolId public lastPoolId;
    address public lastCaller;
    bytes public lastData;
    uint256 public enforceCalls;
    bool public shouldRevert;

    mapping(bytes32 => uint48) public authorizedAfter;

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function enforce(PoolId poolId, address caller, bytes calldata data) external {
        enforceCalls++;
        lastPoolId = poolId;
        lastCaller = caller;
        lastData = data;
        if (shouldRevert) revert Unauthorized();
    }

    function authorize(PoolId, bytes calldata) external {}
    function cancelAuthorization(PoolId, bytes calldata) external {}
}

contract HubManifestTest is Test {
    PoolId constant POOL_A = PoolId.wrap(1);
    address immutable manager = makeAddr("manager");

    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IGateway immutable gateway = IGateway(makeAddr("Gateway"));

    Hub hub = new Hub(gateway, holdings, accounting, hubRegistry, multiAdapter, scm, address(this));
    MockManifest manifest = new MockManifest();

    bytes metadata = "meta";

    function setUp() public {
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, manager),
            abi.encode(true)
        );
        vm.mockCall(address(hubRegistry), abi.encodeWithSelector(hubRegistry.setMetadata.selector), abi.encode());
        // Manifest storage now lives in the registry; the Hub reads/writes through it.
        vm.mockCall(address(hubRegistry), abi.encodeWithSelector(IHubRegistry.setManifest.selector), abi.encode());
        _installManifest(IManifest(address(0))); // default: no manifest installed
    }

    /// @dev Mock the registry to report `m` as the pool's installed manifest (Hub reads through to it).
    function _installManifest(IManifest m) internal {
        vm.mockCall(address(hubRegistry), abi.encodeWithSelector(IHubRegistry.manifest.selector, POOL_A), abi.encode(m));
    }

    // ─── setManifest ──────────────────────────────────────────────────────────

    function testSetManifestByWardWritesThroughToRegistry() public {
        // Ward (this) installs directly; the Hub persists the manifest in the registry.
        vm.expectCall(address(hubRegistry), abi.encodeCall(IHubRegistry.setManifest, (POOL_A, manifest)));
        hub.setManifest(POOL_A, manifest);

        // The Hub's view reads back through the registry.
        _installManifest(manifest);
        assertEq(address(hub.manifest(POOL_A)), address(manifest));
    }

    function testSetManifestByNonManagerNonWardReverts() public {
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, address(0xBAD)),
            abi.encode(false)
        );
        vm.expectRevert(IHub.NotManager.selector);
        vm.prank(address(0xBAD));
        hub.setManifest(POOL_A, manifest);
    }

    function testSetManifestByManagerEnforcesCurrentManifest() public {
        _installManifest(manifest); // current manifest installed

        // A manager replacing the manifest is enforced by the current manifest.
        manifest.setShouldRevert(true);
        vm.expectRevert(IManifest.Unauthorized.selector);
        vm.prank(manager);
        hub.setManifest(POOL_A, manifest);

        // When the current manifest allows it, the replacement is written through to the registry.
        manifest.setShouldRevert(false);
        MockManifest next = new MockManifest();
        vm.expectCall(address(hubRegistry), abi.encodeCall(IHubRegistry.setManifest, (POOL_A, next)));
        vm.prank(manager);
        hub.setManifest(POOL_A, next);
    }

    // ─── enforcement on manager methods ─────────────────────────────────────────

    function testNoManifestSkipsEnforcement() public {
        // No manifest installed: only the manager check applies.
        vm.prank(manager);
        hub.setPoolMetadata(POOL_A, metadata);
        assertEq(manifest.enforceCalls(), 0);
    }

    function testManifestEnforcedOnManagerMethod() public {
        _installManifest(manifest);

        vm.prank(manager);
        hub.setPoolMetadata(POOL_A, metadata);

        assertEq(manifest.enforceCalls(), 1);
        assertEq(manifest.lastCaller(), manager);
        // The manifest receives the exact call's calldata (selector + args).
        assertEq(manifest.lastData(), abi.encodeWithSelector(IHub.setPoolMetadata.selector, POOL_A, metadata));
    }

    function testManagerMethodRevertsWhenManifestReverts() public {
        _installManifest(manifest);
        manifest.setShouldRevert(true);

        vm.expectRevert(IManifest.Unauthorized.selector);
        vm.prank(manager);
        hub.setPoolMetadata(POOL_A, metadata);
    }

    function testManagerCheckPrecedesManifest() public {
        _installManifest(manifest);
        vm.mockCall(
            address(hubRegistry),
            abi.encodeWithSelector(hubRegistry.manager.selector, POOL_A, address(0xBAD)),
            abi.encode(false)
        );

        // Non-manager is rejected before the manifest is consulted.
        vm.expectRevert(IHub.NotManager.selector);
        vm.prank(address(0xBAD));
        hub.setPoolMetadata(POOL_A, metadata);
        assertEq(manifest.enforceCalls(), 0);
    }
}
