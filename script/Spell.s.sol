
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {RelinkV2Eth} from "test/spell/RelinkV2Eth.sol";
import "forge-std/Script.sol";

contract SpellDeployment is Script {
    function run() public {
        vm.startBroadcast();

        new RelinkV2Eth();

        vm.stopBroadcast();
    }
}
