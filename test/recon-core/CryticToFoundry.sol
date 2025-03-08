// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // forge test --match-test test_vault_requestRedeem_1 -vv
    // NOTE: if the requester is not frozen, they can redeem for a frozen recipient
    // TODO: waiting on feedback of if this is expected behavior
    function test_vault_requestRedeem_1() public {
        deployNewTokenPoolAndTranche(2, 0);

        poolManager_updateMember(1525211369);

        poolManager_handleTransferTrancheTokens(1, 2);

        restrictionManager_freeze(0x0000000000000000000000000000000000020000);

        vault_requestRedeem(1, 317773853053177485060848576230726880203767618786530);
    }
}
