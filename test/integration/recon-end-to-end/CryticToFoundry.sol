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

    // forge test --match-test test_asyncVault_maxMint_5 -vvv 
    // NOTE: same as the above
    function test_asyncVault_maxMint_5() public {

        shortcut_deployNewTokenPoolAndShare(27,1,true,false,false);

        shortcut_deposit_sync(0,1001264570074274036555728822370);

        console2.log(" === Before Mint === ");
        asyncVault_maxMint(0,0,0);

    }


    /// === Categorized Issues === ///


    /// === Newest Issues === ///
}
