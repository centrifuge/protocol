// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {FoundryAsserts} from "@chimera/FoundryAsserts.sol";
import {MockERC20} from "@recon/MockERC20.sol";

import {ShareClassId} from "src/core/types/ShareClassId.sol";
import {IShareToken} from "src/core/spoke/interfaces/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {AssetId} from "src/core/types/AssetId.sol";
import {PoolId} from "src/core/types/PoolId.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {AccountId, AccountType} from "src/core/hub/interfaces/IHub.sol";
import {PoolEscrow} from "src/core/spoke/PoolEscrow.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IValuation} from "src/core/hub/interfaces/IValuation.sol";
import {D18} from "src/misc/types/D18.sol";
import {RequestMessageLib} from "src/vaults/libraries/RequestMessageLib.sol";
import {IShareToken} from "src/core/spoke/interfaces/IShareToken.sol";

import {Helpers} from "test/integration/recon-end-to-end/utils/Helpers.sol";
import {TargetFunctions} from "./TargetFunctions.sol";
import {CryticSanity} from "./CryticSanity.sol";

// forge test --match-contract CryticToFoundry -vv
contract CryticToFoundry is Test, TargetFunctions, FoundryAsserts {
    function setUp() public {
        setup();
    }

    // Helper functions to handle bytes calldata parameters
    function hub_updateRestriction_wrapper(uint16 /* chainId */) external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction(chainId, "");
    }

    function hub_updateRestriction_clamped_wrapper() external {
        // TODO: Fix bytes calldata issue - skipping for now
        // hub_updateRestriction_clamped("");
    }

    // forge test --match-test test_crytic -vvv
    function test_crytic() public {}

    /// === Potential Issues === ///

    /// === Categorized Issues === ///

    // forge test --match-test test_doomsday_zeroPrice_noPanics_3 -vvv
    // NOTE: doesn't return 0 for maxDeposit if there's a nonzero maxReserve set
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/3
    function test_doomsday_zeroPrice_noPanics_3() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        doomsday_zeroPrice_noPanics();
    }

    // forge test --match-test test_property_availableGtQueued_26 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/6
    // more of an admin gotcha that should be monitored
    function test_property_availableGtQueued_26() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(1, 0);

        balanceSheet_withdraw(0, 1);

        property_availableGtQueued();
    }

    // forge test --match-test test_property_authorizationBypass_0 -vvv
    // NOTE: issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/10
    function test_property_authorizationBypass_0() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        switch_actor(174920634904368324500);

        balanceSheet_overridePricePoolPerShare(D18.wrap(0));

        property_authorizationBypass();
    }

    // forge test --match-test test_asyncVault_maxWithdraw_6 -vvv
    // NOTE: admin can cause withdraws to fail if the allocate insufficient reserves
    // issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/9
    function test_asyncVault_maxWithdraw_6() public {
        shortcut_deployNewTokenPoolAndShare(
            0,
            5133034522568139688867726516420444120114859979835844169205038226137238,
            false,
            false,
            true,
            false
        );

        shortcut_deposit_sync(0, 0);

        balanceSheet_issue(4982072670431461270);

        shortcut_withdraw_and_claim_clamped(
            275682026535535531214523369603174721404519600237692593863600962365642936,
            1,
            440723970389807847737712878058492487915750186421824605771738298891959171
        );

        asyncVault_maxWithdraw(
            46,
            0,
            3504958222297179309436837969327488759080211702641964324755758
        );
    }

    // forge test --match-test test_property_accounting_and_holdings_soundness_6 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/11
    function test_property_accounting_and_holdings_soundness_6() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, true, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        hub_updateHoldingIsLiability_clamped(true);

        balanceSheet_submitQueuedAssets(0);

        property_accounting_and_holdings_soundness();
    }

    // forge test --match-test test_asyncVault_maxMint_1 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/12
    function test_asyncVault_maxMint_1() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(
            0,
            0,
            18917595704346110,
            1,
            1,
            50924292192
        );

        hub_notifyDeposit(1);

        shortcut_deposit_and_claim(0, 0, 2, 0, 0);

        vault_cancelDepositRequest();

        asyncVault_maxMint(0, 0, 0);
    }
}
