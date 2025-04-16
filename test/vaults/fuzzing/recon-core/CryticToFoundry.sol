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

    // sanity check for system deployment and deposit
    function test_deployNewTokenPoolAndShare_deposit() public {
        deployNewTokenPoolAndShare(18, 1_000_000e18);

        poolManager_updatePricePoolPerShare(1e18, type(uint64).max);
        poolManager_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);
    }

    function test_deployNewTokenPoolAndShare_change_price() public {
        deployNewTokenPoolAndShare(18, 1_000_000e18);

        poolManager_updatePricePoolPerShare(1e18, type(uint64).max);
        poolManager_updateMember(type(uint64).max);

        poolManager_updatePricePoolPerShare(2e18, type(uint64).max);
    }

    function test_vault_deposit_and_redeem() public {
        deployNewTokenPoolAndShare(18, 1_000_000e18);

        poolManager_updatePricePoolPerShare(1e18, type(uint64).max);
        poolManager_updateMember(type(uint64).max);
        
        vault_requestDeposit(1e18, 0);

        asyncRequests_fulfillDepositRequest(1e18 - 1, 1e18, 0, 0);

        vault_deposit(1e18 - 1);

        vault_requestRedeem(1e18 - 1, 0);

        asyncRequests_fulfillRedeemRequest(1e18, 1e18, 0);

        // can only redeem the 1e18 assets
        vault_withdraw(1e18, 0);
    }
}
