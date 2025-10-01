// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonInput} from "./CommonDeployer.s.sol";
import {HubDeployer, HubReport, HubActionBatcher} from "./HubDeployer.s.sol";

import {NAVManager} from "../src/managers/hub/NAVManager.sol";
import {SimplePriceManager} from "../src/managers/hub/SimplePriceManager.sol";

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

        // Rely other
        report.navManager.rely(address(report.hub.hub));
        report.navManager.rely(address(report.hub.hubHandler));
        report.navManager.rely(address(report.hub.holdings));
        report.simplePriceManager.rely(address(report.navManager));
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

        simplePriceManager = SimplePriceManager(
            create3(
                generateSalt("simplePriceManager"),
                abi.encodePacked(type(SimplePriceManager).creationCode, abi.encode(hub, address(batcher)))
            )
        );

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
