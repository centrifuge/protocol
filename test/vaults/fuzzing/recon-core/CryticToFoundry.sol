// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_vault_requestDeposit_4 -vvv 
    function test_vault_requestDeposit_4() public {

        deployNewTokenPoolAndTranche(2,0);

        poolManager_disallowAsset();

        restrictionManager_updateMemberBasic(1525277064);

        poolManager_updateTranchePrice(0,1);

        vault_requestDeposit(1,0);

    }
}