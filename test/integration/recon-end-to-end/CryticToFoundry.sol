// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AccountId, AccountType} from "src/hub/interfaces/IHub.sol";
import {PoolEscrow} from "src/common/PoolEscrow.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IValuation} from "src/common/interfaces/IValuation.sol";
import {D18} from "src/misc/types/D18.sol";
import {RequestMessageLib} from "src/common/libraries/RequestMessageLib.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // Helper functions to handle bytes calldata parameters
    function hub_updateRestriction_wrapper(uint16 chainId) external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction(chainId, "");
    }

    function hub_updateRestriction_clamped_wrapper() external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction_clamped("");
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {
        // TODO: add failing property tests here for debugging
    }

    /// === Potential Issues === ///

    // forge test --match-test test_optimize_maxDeposit_greater_0 -vvv
    function test_optimize_maxDeposit_greater_0() public {
        // Max value: 6680541285479;

        shortcut_deployNewTokenPoolAndShare(
            0, 2143041919793394225184990517963364852588231435786230956613865713711501, false, false, false
        );

        shortcut_request_deposit(
            353266058244111273,
            289,
            2808225,
            5649272889820275245471469757319427940817839515203893610656078129204693045992
        );

        balanceSheet_issue(16959863524853505889821508051117429097);

        shortcut_withdraw_and_claim_clamped(
            24948563696194949097534738073981412730847795109726489012468501556299013517411,
            1375587557,
            59055930033638046365131754211851914515773444673635410048598815021561384717521
        );

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(
            83223019725898119924486676653907346822606427815769443731521280212711078341796,
            4174596,
            14943228121867923935748358918203031574008403248337313074299135211399085189053
        );

        switch_actor(160726349);

        shortcut_deposit_sync(73, 17161000575339933926131652139242);
        asset_mint(0x0000000000000000000000000000000000020000, 170406986501745008686980512511614149806);

        asyncVault_maxDeposit(
            130852067948, 883859, 336644681387797769804767077393537239358796173737373383335960173846558
        );
        console2.log("test_optimize_maxDeposit_greater_0", optimize_maxDeposit_greater());
    }

    /// === Categorized Issues === ///
    // forge test --match-test test_property_holdings_balance_equals_escrow_balance_0 -vvv
    // NOTE: passing in 0 for pricePoolPerShare results in holdingAssetAmount being 0
    // TODO: either add a precondition to check price isn't 0 or accept that property can't be checked
    // function test_property_holdings_balance_equals_escrow_balance_0() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true);

    //     shortcut_deposit_and_claim(0, 1, 1, 1, 0);

    //     property_holdings_balance_equals_escrow_balance();
    // }

    // // forge test --match-test test_property_escrow_balance_2 -vvv
    // // NOTE: issue with ghost tracking variables that needs to be fixed
    // function test_property_escrow_balance_2() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false);

    //     shortcut_deposit_sync(0, 5421286);

    //     property_escrow_balance();
    // }

    // // forge test --match-test test_property_sum_of_received_leq_fulfilled_4 -vvv
    // // NOTE: issue with ghost tracking variables that needs to be fixed
    // function test_property_sum_of_received_leq_fulfilled_4() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 183298046153037838558708965697738377830, true, false, true);

    //     shortcut_deposit_and_claim(0, 1, 1, 1, 0);

    //     shortcut_cancel_redeem_claim_clamped(1, 0, 507631448169772);

    //     shortcut_queue_redemption(1, 0, 68399535177262588966825901408398773);

    //     shortcut_cancel_redeem_clamped(1, 0, 0);

    //     shortcut_withdraw_and_claim_clamped(1, 0, 0);

    //     shortcut_cancel_redeem_claim_clamped(0, 0, 0);

    //     property_sum_of_received_leq_fulfilled();
    // }

    // // forge test --match-test test_property_sum_of_minted_equals_total_supply_5 -vvv
    // // NOTE: issue with ghost tracking variables that needs to be fixed, probably due to not updating correctly for
    // sync
    // // deposits
    // function test_property_sum_of_minted_equals_total_supply_5() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false);

    //     shortcut_deposit_sync(1, 5421521);

    //     property_sum_of_minted_equals_total_supply();
    // }

    // // forge test --match-test test_property_sum_of_shares_received_8 -vvv
    // // NOTE: looks like an issue with ghost tracking variables that needs to be fixed
    // function test_property_sum_of_shares_received_8() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true);

    //     shortcut_deposit_queue_cancel(0, 1, 1, 1, 1, 0);

    //     spoke_deployVault(true);

    //     hub_notifyDeposit(1);

    //     property_sum_of_shares_received();
    // }

    // // forge test --match-test test_property_escrow_share_balance_12 -vvv
    // // NOTE: issue with ghost tracking variables that needs to be fixed
    // function test_property_escrow_share_balance_12() public {
    //     shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true);

    //     shortcut_deposit_queue_cancel(0, 1, 1, 1, 1, 0);

    //     property_escrow_share_balance();
    // }

    // // forge test --match-test test_property_sum_of_pending_redeem_request_15 -vvv
    // // NOTE: issue with ghost tracking variables that needs to be fixed
    // function test_property_sum_of_pending_redeem_request_15() public {
    //     shortcut_deployNewTokenPoolAndShare(7, 1, true, false, false);

    //     shortcut_mint_sync(5, 100002568647520682296840139972);

    //     vault_requestRedeem_clamped(1, 1);

    //     shortcut_redeem_and_claim(4, 1333562963727601499, 42450208829997526553514915981);

    //     property_sum_of_pending_redeem_request();
    // }

    // // forge test --match-test test_property_totalAssets_solvency_17 -vvv
    // // NOTE: pls check the property and see if it can ever actually hold,
    // // it seems like the ability of the admin to pass in a high NAV can easily break this always by always changing
    // the
    // // share price
    // function test_property_totalAssets_solvency_17() public {
    //     shortcut_deployNewTokenPoolAndShare(13, 1, false, false, false);

    //     shortcut_deposit_sync(1, 20);

    //     balanceSheet_withdraw(0, 1);

    //     property_totalAssets_solvency();
    // }
}
