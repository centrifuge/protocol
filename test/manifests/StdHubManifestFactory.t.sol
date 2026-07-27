// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {IMultiAdapter} from "../../src/core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

import {StdHubManifestFactory} from "../../src/manifests/hub/StdHubManifest.sol";
import {IStdHubManifest, IStdHubManifestFactory} from "../../src/manifests/hub/interfaces/IStdHubManifest.sol";

contract StdHubManifestFactoryTest is Test {
    uint48 constant DELAY = 1 days;
    uint48 constant EXPIRY = 7 days;
    uint48 constant ESCALATION = 7 days;

    IHub immutable hub = IHub(makeAddr("Hub"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));
    IMultiAdapter immutable multiAdapter = IMultiAdapter(makeAddr("MultiAdapter"));
    address immutable hubRegistry = makeAddr("HubRegistry");
    address immutable brm = makeAddr("BRM");
    address immutable contractUpdaterForwarder = makeAddr("contractUpdaterForwarder");

    StdHubManifestFactory factory;

    function setUp() public {
        vm.mockCall(address(hub), abi.encodeWithSelector(IHub.hubRegistry.selector), abi.encode(hubRegistry));
        factory = new StdHubManifestFactory(hub, multiAdapter, scm);
    }

    function _config(uint128 maxDeviation) internal view returns (IStdHubManifest.Config memory) {
        return IStdHubManifest.Config({
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
            contractUpdaterForwarder: contractUpdaterForwarder,
            allowlist: new IStdHubManifest.Entry[](0)
        });
    }

    function testFactoryStoresDeps() public view {
        assertEq(address(factory.hub()), address(hub));
        assertEq(address(factory.multiAdapter()), address(multiAdapter));
        assertEq(address(factory.shareClassManager()), address(scm));
    }

    function testFactoryDeploys() public {
        address predicted = factory.previewStdHubManifest(_config(type(uint128).max));

        vm.expectEmit();
        emit IStdHubManifestFactory.DeployStdHubManifest(predicted);
        IStdHubManifest manifest = factory.newStdHubManifest(_config(type(uint128).max));

        assertEq(address(manifest.hub()), address(hub));
        assertEq(address(manifest.multiAdapter()), address(multiAdapter));
        assertEq(address(manifest.shareClassManager()), address(scm));
        assertEq(address(manifest.hubRegistry()), hubRegistry);

        assertEq(manifest.delay(), DELAY);
        assertEq(manifest.expiry(), EXPIRY);
        assertEq(manifest.escalation(), ESCALATION);
        assertEq(manifest.maxBrmPriceDeviation(), type(uint128).max);
        assertEq(manifest.requestManager(), brm);
    }

    function testFactoryPreviewMatchesDeploy() public {
        IStdHubManifest.Config memory config = _config(type(uint128).max);
        address predicted = factory.previewStdHubManifest(config);
        IStdHubManifest manifest = factory.newStdHubManifest(config);
        assertEq(address(manifest), predicted);
    }

    function testFactoryPreviewDiffersByConfig() public view {
        // Distinct policies map to distinct deterministic addresses.
        assertTrue(
            factory.previewStdHubManifest(_config(type(uint128).max)) != factory.previewStdHubManifest(_config(1e16))
        );
    }

    function testFactoryRedeployIdenticalConfigReverts() public {
        factory.newStdHubManifest(_config(type(uint128).max));
        vm.expectRevert();
        factory.newStdHubManifest(_config(type(uint128).max));
    }
}
