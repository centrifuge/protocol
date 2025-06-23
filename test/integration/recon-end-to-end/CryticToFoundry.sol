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
    // forge test --match-test test_asyncVault_maxRedeem_8 -vvv 
    // NOTE: shows that user maintains an extra 1 wei of assets in maxRedeem after a redemption
    // see this issue: https://github.com/centrifuge/protocol-v3/issues/421
    function test_asyncVault_maxRedeem_8() public {
        shortcut_deployNewTokenPoolAndShare(16,29654276389875203551777999997167602027943,true,false,true);
        address poolEscrow = address(poolEscrowFactory.escrow(IBaseVault(_getVault()).poolId()));
        
        shortcut_deposit_and_claim(0,1,143,1,0);

        (, uint128 maxWithdraw,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
        console2.log("maxWithdraw before redeeming and claiming: %e", maxWithdraw);
        // queues a redemption of 1.2407674564261682736e20 shares, 124 assets
        // results in a stuck 1 wei of "virtual" assets in state.maxWithdraw
        // this is because in _processRedeem, state.maxWithdraw = state.maxWithdraw - assetsUp = 124 - 123 = 1
        console2.log("initial pool escrow balance: ", MockERC20(address(IBaseVault(_getVault()).asset())).balanceOf(poolEscrow));
        
        console2.log(" === Before Redeem and Claim === ");
        shortcut_redeem_and_claim_clamped(44055836141804467353088311715299154505223682107,1,60194726908356682833407755266714281307);
        (, maxWithdraw,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
        console2.log("maxWithdraw after redeeming and claiming: ", maxWithdraw);

        console2.log("pool escrow balance after redeeming and claiming: ", MockERC20(address(IBaseVault(_getVault()).asset())).balanceOf(poolEscrow));
        // asset is gets wiped out from the state.maxWithdraw, but is still in the escrow balance
        console2.log(" === Before maxRedeem === ");
        asyncVault_maxRedeem(0,0,0);
        (, maxWithdraw,,,,,,,,) = asyncRequestManager.investments(IBaseVault(_getVault()), _getActor());
        console2.log("maxWithdraw after maxRedeem: ", maxWithdraw);
    }

    // forge test --match-test test_asyncVault_maxDeposit_3 -vvv 
    // NOTE: admin issue with NAV passed in 
    // see this issue: https://github.com/centrifuge/protocol-v3/issues/422
    function test_asyncVault_maxDeposit_3() public {
        shortcut_deployNewTokenPoolAndShare(0,1,false,false,false);
        IBaseVault vault = IBaseVault(_getVault());

        console2.log(" === Before Deposit === ");
        shortcut_deposit_sync(1,2380311791704365157);
        console2.log(" === After Deposit === ");
        poolEscrowFactory.escrow(vault.poolId()).availableBalanceOf(vault.scId(), vault.asset(), 0);

        // console2.log(" === Before Cancel Redeem === ");
        shortcut_cancel_redeem_immediately_issue_and_revoke_clamped(1,1018635830101702210,0);

        asyncVault_maxDeposit(0,0,0);
    }

    // forge test --match-test test_asyncVault_maxDeposit_13 -vvv 
    // NOTE: related to the above, seems to be that claimable cancel deposit request is not being updated correctly
    function test_asyncVault_maxDeposit_13() public {

        shortcut_deployNewTokenPoolAndShare(0,1,true,false,true);

        shortcut_deposit_queue_cancel(0,1,1,1,1,0);

        hub_notifyDeposit(1);

        shortcut_request_deposit(0,1,1,0);

        asyncVault_maxDeposit(0,0,0);

    }

    // forge test --match-test test_asyncVault_maxMint_5 -vvv 
    // NOTE: same as the above
    function test_asyncVault_maxMint_5() public {

        shortcut_deployNewTokenPoolAndShare(27,1,true,false,false);

        shortcut_deposit_sync(0,1001264570074274036555728822370);

        console2.log(" === Before Mint === ");
        asyncVault_maxMint(0,0,0);

    }

    // forge test --match-test test_hub_notifyDeposit_9 -vvv 
    // NOTE: looks like a real issue
    function test_hub_notifyDeposit_9() public {

        shortcut_deployNewTokenPoolAndShare(0,1,false,false,true);

        shortcut_deposit_queue_cancel(0,1,2,1,1,0);

        shortcut_deposit_queue_cancel(0,1,0,1,1,0);

        hub_notifyDeposit(1);

    }

    // forge test --match-test test_property_asset_soundness_7 -vvv 
    // NOTE: might be a real issue or something about property assumption is incorrect
    // TODO(wischli): Investigate
    function test_property_asset_soundness_7() public {

        shortcut_deployNewTokenPoolAndShare(0,1,true,false,false);

        shortcut_mint_sync(1,10000556069156430593232020144282359);

        hub_updateHoldingValuation_clamped(false);

        shortcut_request_deposit(0,1,0,0);

        hub_updateHoldingValue();

        balanceSheet_withdraw(0,1);

        property_asset_soundness();

    }

    // forge test --match-test test_property_gain_soundness_10 -vvv 
    // NOTE: might be a real issue or something about property assumption is incorrect
    // TODO(wischli): Investigate
    function test_property_gain_soundness_10() public {

        shortcut_deployNewTokenPoolAndShare(4,1,true,false,false);

        shortcut_mint_sync(1,100084919394955237472397927082214);

        hub_updateHoldingValuation_clamped(false);

        shortcut_request_deposit(0,1,0,0);

        hub_updateHoldingValue();

        balanceSheet_withdraw(0,1);

        property_gain_soundness();
    }


    /// === Categorized Issues === ///
    // forge test --match-test test_property_holdings_balance_equals_escrow_balance_0 -vvv 
    // NOTE: passing in 0 for pricePoolPerShare results in holdingAssetAmount being 0
    // TODO: either add a precondition to check price isn't 0 or accept that property can't be checked
    function test_property_holdings_balance_equals_escrow_balance_0() public {

        shortcut_deployNewTokenPoolAndShare(0,1,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        property_holdings_balance_equals_escrow_balance();
    }

    // forge test --match-test test_property_escrow_balance_2 -vvv 
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_escrow_balance_2() public {

        shortcut_deployNewTokenPoolAndShare(0,1,false,false,false);

        shortcut_deposit_sync(0,5421286);

        asyncVault_maxDeposit(0,0,0);

        property_escrow_balance();
    }

    // forge test --match-test test_property_sum_of_received_leq_fulfilled_4 -vvv 
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_sum_of_received_leq_fulfilled_4() public {

        shortcut_deployNewTokenPoolAndShare(0,183298046153037838558708965697738377830,true,false,true);

        shortcut_deposit_and_claim(0,1,1,1,0);

        shortcut_cancel_redeem_claim_clamped(1,0,507631448169772);

        shortcut_queue_redemption(1,0,68399535177262588966825901408398773);

        shortcut_cancel_redeem_clamped(1,0,0);

        shortcut_withdraw_and_claim_clamped(1,0,0);

        shortcut_cancel_redeem_claim_clamped(0,0,0);

        property_sum_of_received_leq_fulfilled();

    }

    // forge test --match-test test_property_sum_of_minted_equals_total_supply_5 -vvv 
    // NOTE: issue with ghost tracking variables that needs to be fixed, probably due to not updating correctly for sync deposits
    function test_property_sum_of_minted_equals_total_supply_5() public {

        shortcut_deployNewTokenPoolAndShare(0,1,false,false,false);

        shortcut_deposit_sync(0,5421521);

        asyncVault_maxDeposit(0,0,0);

        property_sum_of_minted_equals_total_supply();
    }

    // forge test --match-test test_property_sum_of_shares_received_8 -vvv 
    // NOTE: looks like an issue with ghost tracking variables that needs to be fixed
    function test_property_sum_of_shares_received_8() public {

        shortcut_deployNewTokenPoolAndShare(0,1,false,false,true);

        shortcut_deposit_queue_cancel(0,1,1,1,1,0);

        spoke_deployVault(true);

        hub_notifyDeposit(1);

        property_sum_of_shares_received();

    }

    // forge test --match-test test_property_escrow_share_balance_12 -vvv 
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_escrow_share_balance_12() public {

        shortcut_deployNewTokenPoolAndShare(0,1,false,false,true);

        shortcut_deposit_queue_cancel(0,1,1,1,1,0);

        property_escrow_share_balance();

    }

    // forge test --match-test test_property_sum_of_pending_redeem_request_15 -vvv 
    // NOTE: issue with ghost tracking variables that needs to be fixed
    function test_property_sum_of_pending_redeem_request_15() public {

        shortcut_deployNewTokenPoolAndShare(7,1,true,false,false);

        shortcut_mint_sync(5,100002568647520682296840139972);

        vault_requestRedeem_clamped(1,1);

        shortcut_redeem_and_claim(4,1333562963727601499,42450208829997526553514915981);

        property_sum_of_pending_redeem_request();
    }

    // forge test --match-test test_property_totalAssets_solvency_17 -vvv 
    // NOTE: pls check the property and see if it can ever actually hold,
    // it seems like the ability of the admin to pass in a high NAV can easily break this always by always changing the share price
    function test_property_totalAssets_solvency_17() public {

        shortcut_deployNewTokenPoolAndShare(13,1,false,false,false);

        shortcut_deposit_sync(1,20);

        balanceSheet_withdraw(0,1);

        property_totalAssets_solvency();

    }

    /// === Newest Issues === ///
    
}
