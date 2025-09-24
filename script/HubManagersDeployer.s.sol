// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {NAVManager} from "../src/managers/hub/NAVManager.sol";
import {SimplePriceManager} from "../src/managers/hub/SimplePriceManager.sol";

import {CommonInput} from "./CommonDeployer.s.sol";
import {HubDeployer, HubReport, HubActionBatcher} from "./HubDeployer.s.sol";

import "forge-std/Script.sol";

struct HubManagersReport {
    HubReport hub;
    NAVManager navManager;
    SimplePriceManager simplePriceManager;
}

contract HubManagersActionBatcher is HubActionBatcher {
    function engageManagers(HubManagersReport memory report) public onlyDeployer {
        // Rely root
        report.navManager.rely(address(report.hub.common.root));
        report.simplePriceManager.rely(address(report.hub.common.root));

        // Rely hub
        report.navManager.rely(address(report.hub.hub));
        report.simplePriceManager.rely(address(report.hub.hub));

        // Rely other
        report.simplePriceManager.rely(address(report.navManager));
        report.navManager.rely(address(report.hub.holdings));
        report.hub.common.gateway.rely(address(report.simplePriceManager));
    }

    function revokeManagers(HubManagersReport memory report) public onlyDeployer {
        report.navManager.deny(address(this));
        report.simplePriceManager.deny(address(this));
    }
}

contract HubManagersDeployer is HubDeployer {
    NAVManager public navManager;
    SimplePriceManager public simplePriceManager;

    function deployHubManagers(CommonInput memory input, HubManagersActionBatcher batcher) public {
        _preDeployHubManagers(input, batcher);
        _postDeployHubManagers(batcher);
    }

    function _preDeployHubManagers(CommonInput memory input, HubManagersActionBatcher batcher) internal {
        _preDeployHub(input, batcher);

        navManager = NAVManager(
            create3(
                generateSalt("navManager"),
                abi.encodePacked(type(NAVManager).creationCode, abi.encode(hub, address(batcher)))
            )
        );

        address simplePriceManagerAddr = create3(
            generateSalt("simplePriceManager"),
            abi.encodePacked(type(SimplePriceManager).creationCode, abi.encode(hub, address(batcher)))
        );
        simplePriceManager = SimplePriceManager(payable(simplePriceManagerAddr));

        batcher.engageManagers(_managersReport());

        register("navManager", address(navManager));
        register("simplePriceManager", address(simplePriceManager));
    }

    function _postDeployHubManagers(HubManagersActionBatcher batcher) internal {
        _postDeployHub(batcher);
    }

    function removeHubManagersDeployerAccess(HubManagersActionBatcher batcher) public {
        removeHubDeployerAccess(batcher);

        batcher.revokeManagers(_managersReport());
    }

    function _managersReport() internal view returns (HubManagersReport memory) {
        return HubManagersReport(_hubReport(), navManager, simplePriceManager);
    }
}
