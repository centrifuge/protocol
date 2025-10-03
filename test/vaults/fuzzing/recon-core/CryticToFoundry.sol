// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";
import {D18} from "src/misc/types/D18.sol";
import {TargetFunctions} from "./TargetFunctions.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

// forge test --match-contract CryticToFoundry --match-path test/vaults/fuzzing/recon-core/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    /// === SANITY CHECKS === ///
    function test_deployNewTokenPoolAndShare_deposit() public {
        deployNewTokenPoolAndShare(18, 1_000_000e18);

        spoke_updatePricePoolPerShare(1e18, type(uint64).max);
        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);
    }

    function test_deployNewTokenPoolAndShare_change_price() public {
        deployNewTokenPoolAndShare(18, 1_000_000e18);

        spoke_updatePricePoolPerShare(1e18, type(uint64).max);
        spoke_updateMember(type(uint64).max);

        spoke_updatePricePoolPerShare(2e18, type(uint64).max);
    }

    function test_vault_deposit_and_redeem() public {
        deployNewTokenPoolAndShare(18, 1_000_000e18);

        spoke_updatePricePoolPerShare(1e18, type(uint64).max);
        spoke_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);

        asyncRequests_fulfillDepositRequest(1e18 - 1, 1e18, 0, 0, D18.wrap(1e18));

        vault_deposit(1e18 - 1);

        vault_requestRedeem(1e18 - 1, 0);

        asyncRequests_fulfillRedeemRequest(1e18, 1e18 - 1, 0, 0);

        // can only redeem the 1e18 assets
        vault_withdraw(1e18, 0);
    }

    /// === REPRODUCERS === ///
    // forge test --match-test test_property_totalAssets_solvency_2 -vvv
    // NOTE: Seems like a real issue, when a request is fulfilled, the totalAssets are calculated using the shares that
    // were minted,
    // but the assets haven't actually been transferred to the vault yet which only happens after calling
    // AsyncVault::deposit
    function test_property_totalAssets_solvency_2() public {
        deployNewTokenPoolAndShare(2, 0);

        spoke_updatePricePoolPerShare(1, 0);

        fullRestrictions_updateMemberBasic(1525116735);

        vault_requestDeposit(1, 0);

        spoke_updatePricePoolPerShare(1, 1525005619);

        asyncRequests_fulfillDepositRequest(0, 1000154974352403727, 0, 0, D18.wrap(1e18));

        property_totalAssets_solvency();
    }

    // forge test --match-test test_property_global_5_inductive_0 -vvv
    function test_property_global_5_inductive_0() public {
        deployNewTokenPoolAndShare(2, 0);

        spoke_updateMember(1525186875);

        spoke_updatePricePoolPerShare(1, 0);

        vault_requestDeposit(1, 0);

        vault_cancelDepositRequest();

        // asyncRequests_fulfillCancelDepositRequest(1,0);

        add_new_asset(0);

        vault_claimCancelDepositRequest(0);

        property_global_5_inductive();
    }
}
