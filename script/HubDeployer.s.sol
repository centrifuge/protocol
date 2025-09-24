// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeployer, CommonInput, CommonReport, CommonActionBatcher} from "./CommonDeployer.s.sol";

import {AssetId, newAssetId} from "../src/common/types/AssetId.sol";

import {Hub} from "../src/hub/Hub.sol";
import {Holdings} from "../src/hub/Holdings.sol";
import {Accounting} from "../src/hub/Accounting.sol";
import {SpokeHandler} from "../src/hub/SpokeHandler.sol";
import {HubRegistry} from "../src/hub/HubRegistry.sol";
import {ShareClassManager} from "../src/hub/ShareClassManager.sol";

import "forge-std/Script.sol";

abstract contract HubConstants {
    uint8 constant ISO4217_DECIMALS = 18;
    AssetId public immutable USD_ID = newAssetId(840);
    AssetId public immutable EUR_ID = newAssetId(978);
}

struct HubReport {
    CommonReport common;
    HubRegistry hubRegistry;
    Accounting accounting;
    Holdings holdings;
    ShareClassManager shareClassManager;
    SpokeHandler spokeHandler;
    Hub hub;
}

contract HubActionBatcher is CommonActionBatcher, HubConstants {
    function engageHub(HubReport memory report) public onlyDeployer {
        // Rely hub
        report.hubRegistry.rely(address(report.hub));
        report.holdings.rely(address(report.hub));
        report.accounting.rely(address(report.hub));
        report.shareClassManager.rely(address(report.hub));
        report.common.gateway.rely(address(report.hub));
        report.common.messageDispatcher.rely(address(report.hub));
        report.common.multiAdapter.rely(address(report.hub));
        report.common.poolEscrowFactory.rely(address(report.hub));

        // Rely spoke handler
        report.shareClassManager.rely(address(report.spokeHandler));
        report.common.messageDispatcher.rely(address(report.spokeHandler));

        // Rely others on spoke handler
        report.spokeHandler.rely(address(report.common.messageProcessor));
        report.spokeHandler.rely(address(report.common.messageDispatcher));

        // Rely others on hub
        report.hub.rely(address(report.common.guardian));

        // Rely root
        report.hubRegistry.rely(address(report.common.root));
        report.accounting.rely(address(report.common.root));
        report.holdings.rely(address(report.common.root));
        report.shareClassManager.rely(address(report.common.root));
        report.hub.rely(address(report.common.root));
        report.spokeHandler.rely(address(report.common.root));

        // File methods
        report.common.messageProcessor.file("hub", address(report.hub));
        report.common.messageDispatcher.file("hub", address(report.hub));

        report.hub.file("sender", address(report.common.messageDispatcher));
        report.hub.file("poolEscrowFactory", address(report.common.poolEscrowFactory));

        report.common.guardian.file("hub", address(report.hub));

        report.spokeHandler.file("hub", address(report.hub));

        // Init configuration
        report.hubRegistry.registerAsset(USD_ID, ISO4217_DECIMALS);
        report.hubRegistry.registerAsset(EUR_ID, ISO4217_DECIMALS);
    }

    function revokeHub(HubReport memory report) public onlyDeployer {
        report.hubRegistry.deny(address(this));
        report.accounting.deny(address(this));
        report.holdings.deny(address(this));
        report.shareClassManager.deny(address(this));
        report.hub.deny(address(this));
        report.spokeHandler.deny(address(this));
    }
}

contract HubDeployer is CommonDeployer, HubConstants {
    // Main contracts
    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    SpokeHandler public spokeHandler;
    Hub public hub;

    function deployHub(CommonInput memory input, HubActionBatcher batcher) public {
        _preDeployHub(input, batcher);
        _postDeployHub(batcher);
    }

    function _preDeployHub(CommonInput memory input, HubActionBatcher batcher) internal {
        _preDeployCommon(input, batcher);

        hubRegistry = HubRegistry(
            create3(generateSalt("hubRegistry"), abi.encodePacked(type(HubRegistry).creationCode, abi.encode(batcher)))
        );

        accounting = Accounting(
            create3(generateSalt("accounting"), abi.encodePacked(type(Accounting).creationCode, abi.encode(batcher)))
        );

        holdings = Holdings(
            create3(
                generateSalt("holdings"),
                abi.encodePacked(type(Holdings).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        shareClassManager = ShareClassManager(
            create3(
                generateSalt("shareClassManager"),
                abi.encodePacked(type(ShareClassManager).creationCode, abi.encode(hubRegistry, batcher))
            )
        );

        hub = Hub(
            create3(
                generateSalt("hub"),
                abi.encodePacked(
                    type(Hub).creationCode,
                    abi.encode(
                        address(gateway),
                        address(holdings),
                        address(accounting),
                        address(hubRegistry),
                        address(multiAdapter),
                        address(shareClassManager),
                        batcher
                    )
                )
            )
        );

        spokeHandler = SpokeHandler(
            create3(
                generateSalt("spokeHandler"),
                abi.encodePacked(
                    type(SpokeHandler).creationCode,
                    abi.encode(
                        address(hub), address(holdings), address(hubRegistry), address(shareClassManager), batcher
                    )
                )
            )
        );

        batcher.engageHub(_hubReport());

        register("hubRegistry", address(hubRegistry));
        register("accounting", address(accounting));
        register("holdings", address(holdings));
        register("shareClassManager", address(shareClassManager));
        register("spokeHandler", address(spokeHandler));
        register("hub", address(hub));
    }

    function _postDeployHub(HubActionBatcher batcher) internal {
        _postDeployCommon(batcher);
    }

    function removeHubDeployerAccess(HubActionBatcher batcher) public {
        removeCommonDeployerAccess(batcher);
        batcher.revokeHub(_hubReport());
    }

    function _hubReport() internal view returns (HubReport memory) {
        return HubReport(_commonReport(), hubRegistry, accounting, holdings, shareClassManager, spokeHandler, hub);
    }
}
