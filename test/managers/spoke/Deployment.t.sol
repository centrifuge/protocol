// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SpokeManagersDeployer, SpokeManagersActionBatcher} from "../../../script/SpokeManagersDeployer.s.sol";

import "forge-std/Test.sol";

import {CommonDeploymentInputTest} from "../../common/Deployment.t.sol";

contract ManagersDeploymentTest is SpokeManagersDeployer, CommonDeploymentInputTest {
    function setUp() public {
        SpokeManagersActionBatcher batcher = new SpokeManagersActionBatcher();
        deploySpokeManagers(_commonInput(), batcher);
        removeSpokeManagersDeployerAccess(batcher);
    }

    function testOnOfframpManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(onOfframpManagerFactory.contractUpdater()), address(contractUpdater));
        assertEq(address(onOfframpManagerFactory.balanceSheet()), address(balanceSheet));
    }

    function testMerkleProofManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(merkleProofManagerFactory.contractUpdater()), address(contractUpdater));
        assertEq(address(merkleProofManagerFactory.balanceSheet()), address(balanceSheet));
    }

    function testQueueManager() public view {
        // dependencies set correctly
        assertEq(address(queueManager.contractUpdater()), address(contractUpdater));
        assertEq(address(queueManager.balanceSheet()), address(balanceSheet));
    }
}
