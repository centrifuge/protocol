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

    function test_recon_deposit() public {
        deployNewTokenPoolAndTranche(18, type(uint88).max);

        poolManager_updateTranchePrice(1e18, 1);
        poolManager_updateMember(type(uint64).max);
        vault_requestDeposit(1e18, 1);

        // investmentManager_fulfillDepositRequest(1e18, 1e18, 0, 1);
    }
}