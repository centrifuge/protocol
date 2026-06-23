// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {CentrifugeIntegrationTestWithUtils} from "./Integration.t.sol";

import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {IManifest} from "../../src/core/hub/interfaces/IManifest.sol";
import {ITrustedContractUpdate} from "../../src/core/utils/interfaces/IContractUpdate.sol";

import {SupervisorFactory} from "../../src/managers/hub/Supervisor.sol";
import {ISupervisor, TrustedCall} from "../../src/managers/hub/interfaces/ISupervisor.sol";

import {StdManifest} from "../../src/manifests/StdManifest.sol";
import {IStdManifest} from "../../src/manifests/interfaces/IStdManifest.sol";

/// @notice End-to-end test of the manifest circuit breaker on a full single-chain deployment:
///         a pool with a real StdManifest installed and a Supervisor wired as a hub manager,
///         exercising the in-policy / out-of-policy / authorize / sentinel-veto flows.
contract StdManifestIntegrationTest is CentrifugeIntegrationTestWithUtils {
    uint48 constant POLICY_DELAY = 1 days;
    uint48 constant POLICY_EXPIRY = 7 days;
    uint48 constant POLICY_ESCALATION = 7 days;

    address immutable operator = makeAddr("operator");
    address immutable mockUpdater = makeAddr("mockUpdater");
    address immutable sentinel = makeAddr("sentinel");
    address immutable newManager = makeAddr("newManager");

    StdManifest manifest;
    ISupervisor supervisor;

    function setUp() public override {
        super.setUp();
        _createPool();

        // Deploy the pool's Supervisor (sentinel registry) and StdManifest.
        supervisor = new SupervisorFactory(IHub(address(hub))).newSupervisor(POOL_A, mockUpdater);
        manifest = new StdManifest(
            IHub(address(hub)),
            multiAdapter,
            shareClassManager,
            IStdManifest.Config({
                delay: POLICY_DELAY,
                expiry: POLICY_EXPIRY,
                escalation: POLICY_ESCALATION,
                maxPriceDelta: 0,
                thresholdPerSecond: 0,
                onchainAccounting: false,
                navManager: address(0),
                simplePriceManager: address(0),
                requestManager: address(batchRequestManager),
                allowlist: new IStdManifest.Entry[](0)
            })
        );

        // Register the operator and the Supervisor as hub managers BEFORE installing the manifest
        // (no manifest yet, so these grants are unguarded). The operator authorizes out-of-policy
        // calls directly on the manifest; the Supervisor must be a manager so it can reach the
        // manifest's cancelAuthorization on behalf of sentinels.
        vm.startPrank(FM);
        hub.updateHubManager(POOL_A, operator, true);
        hub.updateHubManager(POOL_A, address(supervisor), true);
        vm.stopPrank();

        // Install the manifest via the ward (Root) break-glass path.
        vm.prank(address(root));
        hub.setManifest(POOL_A, manifest);
    }

    function _grantManagerCall() internal view returns (bytes memory) {
        return abi.encodeCall(IHub.updateHubManager, (POOL_A, newManager, true));
    }

    function testInPolicyRunsSynchronously() public {
        // setPoolMetadata is in policy: runs immediately, no authorization.
        vm.prank(FM);
        hub.setPoolMetadata(POOL_A, "metadata");
    }

    function testBrmUpdateContractIsInPolicy() public {
        // updateContract targeting the configured request manager (BRM) is in policy: routine keeper ops
        // (approve/issue/revoke/forceCancel) run synchronously, no authorization needed. Verified at the
        // manifest seam: enforce of a BRM-targeted call neither reverts nor consumes an authorization.
        bytes32 target = bytes32(bytes20(address(batchRequestManager)));
        // Opaque payload: target is pinned, so its contents are not inspected by the classifier.
        bytes memory payload = abi.encode(uint8(1), bytes16(0));
        bytes memory call =
            abi.encodeCall(IHub.updateContract, (POOL_A, SC_1, uint16(0), target, payload, 0, address(0)));

        // In policy: enforce succeeds with no prior authorize() (deny-by-default would revert Unauthorized).
        vm.prank(address(hub));
        manifest.enforce(POOL_A, FM, call);
    }

    function testOutOfPolicyReverts() public {
        // Granting a hub manager is out of policy; without an authorization it reverts.
        vm.prank(FM);
        vm.expectRevert(IManifest.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
    }

    function testAuthorizeThenExecute() public {
        // Operator (a hub manager) pre-authorizes the exact call directly on the manifest.
        vm.prank(operator);
        manifest.authorize(POOL_A, _grantManagerCall());

        // Not matured yet -> still reverts.
        vm.prank(FM);
        vm.expectRevert(IManifest.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);

        // After the delay it executes (consuming the authorization).
        skip(POLICY_DELAY);
        vm.prank(FM);
        hub.updateHubManager(POOL_A, newManager, true);
        assertTrue(hubRegistry.manager(POOL_A, newManager));
    }

    function testSentinelCanVeto() public {
        // Operator authorizes, sentinel (installed via the contract updater) cancels during the window.
        vm.prank(mockUpdater);
        ITrustedContractUpdate(address(supervisor))
            .trustedCall(POOL_A, SC_1, abi.encode(TrustedCall.AddSentinel, sentinel));

        vm.prank(operator);
        manifest.authorize(POOL_A, _grantManagerCall());

        vm.prank(sentinel);
        supervisor.cancelAuthorization(_grantManagerCall());

        // Vetoed: even after the delay the call reverts.
        skip(POLICY_DELAY);
        vm.prank(FM);
        vm.expectRevert(IManifest.Unauthorized.selector);
        hub.updateHubManager(POOL_A, newManager, true);
    }

    function testReplacingManifestUsesEscalation() public {
        StdManifest next = new StdManifest(
            IHub(address(hub)),
            multiAdapter,
            shareClassManager,
            IStdManifest.Config({
                delay: POLICY_DELAY,
                expiry: POLICY_EXPIRY,
                escalation: POLICY_ESCALATION,
                maxPriceDelta: 0,
                thresholdPerSecond: 0,
                onchainAccounting: false,
                navManager: address(0),
                simplePriceManager: address(0),
                requestManager: address(batchRequestManager),
                allowlist: new IStdManifest.Entry[](0)
            })
        );
        bytes memory call = abi.encodeCall(IHub.setManifest, (POOL_A, next));

        // A manager replacing the manifest is out of policy and waits the longer escalation delay.
        vm.prank(operator);
        manifest.authorize(POOL_A, call);

        skip(POLICY_DELAY); // past the standard delay but not escalation
        vm.prank(FM);
        vm.expectRevert(IManifest.Unauthorized.selector);
        hub.setManifest(POOL_A, next);

        skip(POLICY_ESCALATION - POLICY_DELAY);
        vm.prank(FM);
        hub.setManifest(POOL_A, next);
        assertEq(address(hub.manifest(POOL_A)), address(next));
    }
}
