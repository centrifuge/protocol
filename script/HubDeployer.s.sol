// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeployer, CommonInput, CommonReport, CommonActionBatcher} from "./CommonDeployer.s.sol";

import {AssetId, newAssetId} from "../src/common/types/AssetId.sol";

import {Hub} from "../src/hub/Hub.sol";
import {Holdings} from "../src/hub/Holdings.sol";
import {Accounting} from "../src/hub/Accounting.sol";
import {HubHelpers} from "../src/hub/HubHelpers.sol";
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
    HubHelpers hubHelpers;
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
        report.hubHelpers.rely(address(report.hub));
        report.common.poolEscrowFactory.rely(address(report.hub));

        // Rely hub helpers
        report.accounting.rely(address(report.hubHelpers));
        report.shareClassManager.rely(address(report.hubHelpers));
        report.common.messageDispatcher.rely(address(report.hubHelpers));

        // Rely others on hub
        report.hub.rely(address(report.common.messageProcessor));
        report.hub.rely(address(report.common.messageDispatcher));
        report.hub.rely(address(report.common.guardian));

        // Rely root
        report.hubRegistry.rely(address(report.common.root));
        report.accounting.rely(address(report.common.root));
        report.holdings.rely(address(report.common.root));
        report.shareClassManager.rely(address(report.common.root));
        report.hub.rely(address(report.common.root));
        report.hubHelpers.rely(address(report.common.root));

        // File methods
        report.common.messageProcessor.file("hub", address(report.hub));
        report.common.messageDispatcher.file("hub", address(report.hub));

        report.hub.file("sender", address(report.common.messageDispatcher));
        report.hub.file("poolEscrowFactory", address(report.common.poolEscrowFactory));

        report.common.guardian.file("hub", address(report.hub));

        report.hubHelpers.file("hub", address(report.hub));

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
        report.hubHelpers.deny(address(this));
    }
}

contract HubDeployer is CommonDeployer, HubConstants {
    // Main contracts
    HubRegistry public hubRegistry;
    Accounting public accounting;
    Holdings public holdings;
    ShareClassManager public shareClassManager;
    HubHelpers public hubHelpers;
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

        hubHelpers = HubHelpers(
            create3(
                generateSalt("hubHelpers"),
                abi.encodePacked(
                    type(HubHelpers).creationCode,
                    abi.encode(
                        address(holdings),
                        address(accounting),
                        address(hubRegistry),
                        address(messageDispatcher),
                        address(shareClassManager),
                        batcher
                    )
                )
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
                        address(hubHelpers),
                        address(accounting),
                        address(hubRegistry),
                        address(shareClassManager),
                        batcher
                    )
                )
            )
        );

        batcher.engageHub(_hubReport());

        register("hubRegistry", address(hubRegistry));
        register("accounting", address(accounting));
        register("holdings", address(holdings));
        register("shareClassManager", address(shareClassManager));
        register("hubHelpers", address(hubHelpers));
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
        return HubReport(_commonReport(), hubRegistry, accounting, holdings, shareClassManager, hubHelpers, hub);
    }
}
