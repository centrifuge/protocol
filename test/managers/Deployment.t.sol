// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ManagersDeployer} from "script/ManagersDeployer.s.sol";

import {CommonDeploymentInputTest} from "test/common/Deployment.t.sol";

import "forge-std/Test.sol";

contract ManagersDeploymentTest is ManagersDeployer, CommonDeploymentInputTest {
    function setUp() public {
        deployManagers(_commonInput(), address(this));
        removeManagersDeployerAccess(address(this));
    }

    function testOnOfframpManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(onOfframpManagerFactory.spoke()), address(spoke));
        assertEq(address(onOfframpManagerFactory.balanceSheet()), address(balanceSheet));
    }

    function testMerkleProofManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(merkleProofManagerFactory.spoke()), address(spoke));
    }
}
