// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Script.sol";

import {ISafe} from "src/common/Guardian.sol";
import {PoolsDeployer} from "script/PoolsDeployer.s.sol";
import {VaultsDeployer} from "script/VaultsDeployer.s.sol";

contract FullDeployer is PoolsDeployer, VaultsDeployer {
    function deployFull(ISafe adminSafe_, address deployer) public {
        super.deployPools(adminSafe_, deployer);
        super.deployVaults(adminSafe_, deployer);

        //_file();
        //_rely();
    }

    /*
    function _file() private {
        // TODO: link CP and CV MessageProcessors with the managers
    }

    function _rely() private {}
    */

    function removeFullDeployerAccess(address deployer) public {
        super.removePoolsDeployerAccess(deployer);
        super.removeVaultsDeployerAccess(deployer);
    }
}
