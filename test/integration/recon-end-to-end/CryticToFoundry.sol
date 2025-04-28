// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {TargetFunctions} from "./TargetFunctions.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
// forge test --match-contract CryticToFoundry --match-path test/integration/recon-end-to-end/CryticToFoundry.sol -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    /// === SANITY CHECKS === ///
    function test_shortcut_deployNewTokenPoolAndShare_deposit() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false);

        // poolManager_updatePricePoolPerShare(1e18, type(uint64).max);
        poolManager_updateMember(type(uint64).max);

        vault_requestDeposit(1e18, 0);
    }

    function test_vault_deposit_and_fulfill() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false);

        // price needs to be set in valuation before calling updatePricePoolPerShare
        transientValuation_setPrice_clamped(poolId, 1e18);

        hub_updatePricePerShare(poolId, scId, 1e18);
        hub_notifySharePrice_clamped(0,0);
        hub_notifyAssetPrice_clamped(0,0);
        
        poolManager_updateMember(type(uint64).max);
        
        vault_requestDeposit(1e18, 0);

        hub_approveDeposits(poolId, scId, assetId, 1e18, transientValuation);
        hub_issueShares(poolId, scId, assetId, 1e18);
       
        // need to call claimDeposit first to mint the shares
        hub_notifyDeposit(poolId, scId, assetId, MAX_CLAIMS);

        vault_deposit(1e18);
    }

    function test_vault_deposit_and_fulfill_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false);
        
        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, false, 0);
    }

    function test_vault_deposit_and_redeem() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false);

        transientValuation_setPrice_clamped(poolId, 1e18);

        hub_updatePricePerShare(poolId, scId, 1e18);
        hub_notifySharePrice_clamped(0,0);
        hub_notifyAssetPrice_clamped(0,0);
        poolManager_updateMember(type(uint64).max);
        
        vault_requestDeposit(1e18, 0);

        transientValuation_setPrice_clamped(poolId, 1e18);

        hub_approveDeposits(poolId, scId, assetId, 1e18, transientValuation);
        hub_issueShares(poolId, scId, assetId, 1e18);
       
        // need to call claimDeposit first to mint the shares
        hub_notifyDeposit(poolId, scId, assetId, MAX_CLAIMS);

        vault_deposit(1e18);

        vault_requestRedeem(1e18, 0);

        hub_approveRedeems(poolId, scId, assetId, 1e18);
        hub_revokeShares(poolId, scId, 1e18, transientValuation);
        
        hub_notifyRedeem(poolId, ShareClassId.wrap(scId).raw(), assetId, MAX_CLAIMS);

        vault_withdraw(1e18, 0);
    }

    function test_vault_redeem_and_fulfill_shortcut() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false);

        shortcut_deposit_and_claim(1e18, 1e18, 1e18, 1e18, false, 0);

        shortcut_redeem_and_claim(1e18, 1e18, false, 0);
    }

    function test_shortcut_deployNewTokenPoolAndShare_change_price() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false);

        transientValuation_setPrice_clamped(poolId, 1e18);

        hub_updatePricePerShare(poolId, scId, 1e18);
        hub_notifySharePrice_clamped(0,0);
        hub_notifyAssetPrice_clamped(0,0);
        poolManager_updateMember(type(uint64).max);
    }

    function test_shortcut_deployNewTokenPoolAndShare_only() public {
        shortcut_deployNewTokenPoolAndShare(18, 12, false, false);
    }

    /// === REPRODUCERS === ///
    // forge test --match-test test_property_totalAssets_solvency_2 -vvv 
    // NOTE: Seems like a real issue, when a request is fulfilled, the totalAssets are calculated using the shares that were minted, 
    // but the assets haven't actually been transferred to the vault yet which only happens after calling AsyncVault::deposit
    function test_property_totalAssets_solvency_2() public {

        shortcut_deployNewTokenPoolAndShare(2, 12, false, false);

        // poolManager_updatePricePoolPerShare(1,0);

        restrictedTransfers_updateMemberBasic(1525116735);

        vault_requestDeposit(1,0);

        // poolManager_updatePricePoolPerShare(1,1525005619);

        // asyncRequests_fulfillDepositRequest(0,1000154974352403727,0,0);

        property_totalAssets_solvency();
    }

    // forge test --match-test test_property_global_5_inductive_0 -vvv 
    function test_property_global_5_inductive_0() public {

        shortcut_deployNewTokenPoolAndShare(2, 12, false, false);

        poolManager_updateMember(1525186875);

        // poolManager_updatePricePoolPerShare(1,0);

        vault_requestDeposit(1,0);

        vault_cancelDepositRequest();

        // asyncRequests_fulfillCancelDepositRequest(1,0);

        add_new_asset(0);

        vault_claimCancelDepositRequest(0);

        property_global_5_inductive();

    }
   


}
