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

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry --match-path test/integration/recon-end-to-end/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    /// === Potential Issues === ///

    /// === Categorized Issues === ///
    // forge test --match-test test_property_holdings_balance_equals_escrow_balance_0 -vvv
    // NOTE: passing in 0 for pricePoolPerShare results in holdingAssetAmount being 0
    // TODO: either add a precondition to check price isn't 0 or accept that property can't be checked
    function test_property_holdings_balance_equals_escrow_balance_0() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true);

        shortcut_deposit_and_claim(0, 1, 1, 1, 0);

        property_holdings_balance_equals_escrow_balance();
    }

    // forge test --match-test test_property_escrow_balance_2 -vvv
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_escrow_balance_2() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false);

        shortcut_deposit_sync(0, 5421286);

        property_escrow_balance();
    }

    // forge test --match-test test_property_sum_of_received_leq_fulfilled_4 -vvv
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_sum_of_received_leq_fulfilled_4() public {
        shortcut_deployNewTokenPoolAndShare(0, 183298046153037838558708965697738377830, true, false, true);

        shortcut_deposit_and_claim(0, 1, 1, 1, 0);

        shortcut_cancel_redeem_claim_clamped(1, 0, 507631448169772);

        shortcut_queue_redemption(1, 0, 68399535177262588966825901408398773);

        shortcut_cancel_redeem_clamped(1, 0, 0);

        shortcut_withdraw_and_claim_clamped(1, 0, 0);

        shortcut_cancel_redeem_claim_clamped(0, 0, 0);

        property_sum_of_received_leq_fulfilled();
    }

    // forge test --match-test test_property_sum_of_minted_equals_total_supply_5 -vvv
    // NOTE: issue with ghost tracking variables that needs to be fixed, probably due to not updating correctly for sync
    // deposits
    function test_property_sum_of_minted_equals_total_supply_5() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false);

        shortcut_deposit_sync(1, 5421521);

        property_sum_of_minted_equals_total_supply();
    }

    // forge test --match-test test_property_sum_of_shares_received_8 -vvv
    // NOTE: looks like an issue with ghost tracking variables that needs to be fixed
    function test_property_sum_of_shares_received_8() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true);

        shortcut_deposit_queue_cancel(0, 1, 1, 1, 1, 0);

        spoke_deployVault(true);

        hub_notifyDeposit(1);

        property_sum_of_shares_received();
    }

    // forge test --match-test test_property_escrow_share_balance_12 -vvv
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_escrow_share_balance_12() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true);

        shortcut_deposit_queue_cancel(0, 1, 1, 1, 1, 0);

        property_escrow_share_balance();
    }

    // forge test --match-test test_property_sum_of_pending_redeem_request_15 -vvv
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_sum_of_pending_redeem_request_15() public {
        shortcut_deployNewTokenPoolAndShare(7, 1, true, false, false);

        shortcut_mint_sync(5, 100002568647520682296840139972);

        vault_requestRedeem_clamped(1, 1);

        shortcut_redeem_and_claim(4, 1333562963727601499, 42450208829997526553514915981);

        property_sum_of_pending_redeem_request();
    }

    // forge test --match-test test_property_totalAssets_solvency_17 -vvv
    // NOTE: pls check the property and see if it can ever actually hold,
    // it seems like the ability of the admin to pass in a high NAV can easily break this always by always changing the
    // share price
    function test_property_totalAssets_solvency_17() public {
        shortcut_deployNewTokenPoolAndShare(13, 1, false, false, false);

        shortcut_deposit_sync(1, 20);

        balanceSheet_withdraw(0, 1);

        property_totalAssets_solvency();
    }

    /// === Newest Issues === ///
}
