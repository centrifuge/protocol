// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "src/common/Guardian.sol";

import "forge-std/Script.sol";
import {PoolsDeployer} from "script/PoolsDeployer.s.sol";
import {VaultsDeployer} from "script/VaultsDeployer.s.sol";

contract FullDeployer is PoolsDeployer, VaultsDeployer {
    function deployFull(ISafe adminSafe_, address deployer) public {
        deployPools(adminSafe_, deployer);
        deployVaults(adminSafe_, deployer);
    }

    function removeFullDeployerAccess(address deployer) public {
        removePoolsDeployerAccess(deployer);
        removeVaultsDeployerAccess(deployer);
    }
}
