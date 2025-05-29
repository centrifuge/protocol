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
import {PoolEscrow} from "src/spoke/Escrow.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry --match-path test/integration/recon-end-to-end/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    /// === Potential Issues === ///
    // forge test --match-test test_asyncVault_maxRedeem_8 -vvv 
    // NOTE: shows that user maintains an extra 1 wei in maxRedeem after a redemption
    // this is only a precondition, optimization property will determine what the max difference amount can be 
    function test_asyncVault_maxRedeem_8() public {

        shortcut_deployNewTokenPoolAndShare(16,29654276389875203551777999997167602027943,true,false,true);

        shortcut_deposit_and_claim(0,1,143,1,0);

        shortcut_redeem_and_claim_clamped(44055836141804467353088311715299154505223682107,1,60194726908356682833407755266714281307);

        asyncVault_maxRedeem(0,0,0);

    }

    // forge test --match-test test_asyncVault_maxDeposit_3 -vvv 
    // NOTE: potential issue with rounding
    function test_asyncVault_maxDeposit_3() public {

        shortcut_deployNewTokenPoolAndShare(0,1,false,false,false);

        shortcut_deposit_sync(1,2380311791704365157);

        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(1,1018635830101702210,0);

        asyncVault_maxDeposit(0,0,0);

    }

    // forge test --match-test test_asyncVault_maxMint_5 -vvv 
    function test_asyncVault_maxMint_5() public {

        shortcut_deployNewTokenPoolAndShare(27,1,true,false,false);

        shortcut_deposit_sync(0,1001264570074274036555728822370);

        asyncVault_maxMint(0,0,0);

    }

    // forge test --match-test test_property_totalAssets_solvency_13 -vvv 
    // NOTE: indicates a discrepancy between the totalAssets and actualAssets, root cause TBD
    // NOTE: this is only a precondition, optimize_totalAssets_solvency is used to determine the maximum possible difference between totalAssets and actualAssets
    // forge test --match-test test_property_totalAssets_solvency_12 -vvv 
    function test_property_totalAssets_solvency_12() public {

        shortcut_deployNewTokenPoolAndShare(12,2099372101097792568170330428032486163036476777498747403522292624632190,true,false,true);

        shortcut_deposit_and_claim(0,1,2,1,243);

        hub_updateSharePrice(0,hex"12",2504724);

        hub_notifySharePrice(0);

        property_totalAssets_solvency();

    }

    // forge test --match-test test_property_account_totalDebit_and_totalCredit_leq_max_int128_8 -vvv 
    // NOTE: might be an unsafe casting or irrelevant with latest implementation
    function test_property_account_totalDebit_and_totalCredit_leq_max_int128_8() public {

        shortcut_deployNewTokenPoolAndShare(0,1,false,false,false);

        hub_addShareClass(2);

        hub_updateJournal_clamped(0,0,340282366920938463463374607431768211455,340282366920938463463374607431768211455);

        property_account_totalDebit_and_totalCredit_leq_max_int128();

    }


    /// === Categorized Issues === ///
    // forge test --match-test test_property_escrow_share_balance_8 -vvv 
    // NOTE: looks like an issue with ghost tracking
    function test_property_escrow_share_balance_8() public {

        shortcut_deployNewTokenPoolAndShare(2,1,false,false,true);

        shortcut_deposit_and_claim(0,4,1,25,0);

        shortcut_queue_redemption(1,0,0);

        property_escrow_share_balance();

    }

    // forge test --match-test test_property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount_10 -vvv 
    // NOTE: might be an issue with not checking previous epochs
    function test_property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount_10() public {

        shortcut_deployNewTokenPoolAndShare(0,2739917975647239028567165394084111319569479035714252026947453096283,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,312);

        shortcut_queue_redemption(1,10044207105274,0);

        shortcut_cancel_redeem_claim_clamped(8448991857867710314527286738020113534764412038154406736803557,0,2);

        shortcut_queue_redemption(1,368127116196650982403211,3137074433482099721841043092394058031879436671929572534935832);

        property_eligible_user_redemption_amount_leq_approved_asset_redemption_amount();

    }


    /// === Newest Issues === ///
}
