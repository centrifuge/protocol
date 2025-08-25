// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {CommonDeploymentInputTest} from "../common/Deployment.t.sol";

import {ManagersDeployer, ManagersActionBatcher} from "../../script/ManagersDeployer.s.sol";

import "forge-std/Test.sol";

contract ManagersDeploymentTest is ManagersDeployer, CommonDeploymentInputTest {
    function setUp() public {
        ManagersActionBatcher batcher = new ManagersActionBatcher();
        deployManagers(_commonInput(), batcher);
        removeManagersDeployerAccess(batcher);
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
}
