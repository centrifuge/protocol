// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../../common/Deployment.t.sol";

import {HubManagersDeployer, HubManagersActionBatcher} from "../../../script/HubManagersDeployer.s.sol";

import "forge-std/Test.sol";

contract ManagersDeploymentTest is HubManagersDeployer, CommonDeploymentInputTest {
    function setUp() public {
        HubManagersActionBatcher batcher = new HubManagersActionBatcher();
        deployHubManagers(_commonInput(), batcher);
        removeHubManagersDeployerAccess(batcher);
    }

    function testNavManager() public view {
        // dependencies set correctly
        assertEq(address(navManager.hub()), address(hub));
    }

    function testSimplePriceManager() public view {
        // dependencies set correctly
        assertEq(address(simplePriceManager.hub()), address(hub));
    }
}
