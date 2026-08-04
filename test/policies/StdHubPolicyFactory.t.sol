// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

import {StdHubPolicyFactory} from "../../src/policies/hub/StdHubPolicy.sol";
import {IStdHubPolicy, IStdHubPolicyFactory} from "../../src/policies/hub/interfaces/IStdHubPolicy.sol";

contract StdHubPolicyFactoryTest is Test {
    uint48 constant DELAY = 1 days;
    uint48 constant EXPIRY = 7 days;
    uint48 constant ESCALATION = 7 days;

    IHub immutable hub = IHub(makeAddr("Hub"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    address immutable hubRegistry = makeAddr("HubRegistry");
    address immutable brm = makeAddr("BRM");

    StdHubPolicyFactory factory;

    function setUp() public {
        vm.mockCall(address(hub), abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        factory = new StdHubPolicyFactory(hub, multiAdapter, scm);
    }

    function _config(uint128 maxDeviation) internal view returns (IStdHubPolicy.Config memory) {
        return IStdHubPolicy.Config({
            delay: DELAY,
            expiry: EXPIRY,
            escalation: ESCALATION,
            maxAbsolutePriceDelta: 0,
            thresholdPerSecond: 0,
            maxBrmPriceDeviation: maxDeviation,
            onchainAccounting: false,
            navManager: address(0),
            simplePriceManager: address(0),
            requestManager: brm,
            bridgingHook: address(0),
            oracleValuation: address(0),
            allowlist: new IStdHubPolicy.Entry[](0)
        });
    }

    function testFactoryStoresDeps() public view {
        assertEq(address(factory.hub()), address(hub));
        assertEq(address(factory.multiAdapter()), address(multiAdapter));
        assertEq(address(factory.shareClassManager()), address(scm));
    }

    function testFactoryDeploys() public {
        address predicted = factory.previewHubPolicy(_config(type(uint128).max));

        vm.expectEmit();
        emit IStdHubPolicyFactory.DeployHubPolicy(predicted);
        IStdHubPolicy policy = factory.newHubPolicy(_config(type(uint128).max));

        assertEq(address(policy.hub()), address(hub));
        assertEq(address(policy.multiAdapter()), address(multiAdapter));
        assertEq(address(policy.shareClassManager()), address(scm));
        assertEq(address(policy.hubRegistry()), hubRegistry);

        assertEq(policy.delay(), DELAY);
        assertEq(policy.expiry(), EXPIRY);
        assertEq(policy.escalation(), ESCALATION);
        assertEq(policy.maxBrmPriceDeviation(), type(uint128).max);
        assertEq(policy.requestManager(), brm);
    }

    function testFactoryPreviewMatchesDeploy() public {
        IStdHubPolicy.Config memory config = _config(type(uint128).max);
        address predicted = factory.previewHubPolicy(config);
        IStdHubPolicy policy = factory.newHubPolicy(config);
        assertEq(address(policy), predicted);
    }

    function testFactoryPreviewDiffersByConfig() public view {
        // Distinct policies map to distinct deterministic addresses.
        assertTrue(factory.previewHubPolicy(_config(type(uint128).max)) != factory.previewHubPolicy(_config(1e16)));
    }

    function testFactoryRedeployIdenticalConfigReverts() public {
        factory.newHubPolicy(_config(type(uint128).max));
        vm.expectRevert();
        factory.newHubPolicy(_config(type(uint128).max));
    }
}
