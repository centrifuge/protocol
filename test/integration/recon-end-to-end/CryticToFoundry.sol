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

    // forge test --match-test test_property_assetQueueCounterConsistency_11 -vvv
    function test_property_assetQueueCounterConsistency_11() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, true, false);

        shortcut_deposit_queue_cancel(0, 0, 1, 1, 0, 0);

        property_assetQueueCounterConsistency();
    }

    // forge test --match-test test_property_shareQueueFlipBoundaries_26 -vvv
    function test_property_shareQueueFlipBoundaries_26() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_request_deposit(0, 0, 0, 0);

        balanceSheet_issue(1);

        property_shareQueueFlipBoundaries();
    }

    // forge test --match-test test_asyncVault_maxMint_5 -vvv
    function test_asyncVault_maxMint_5() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        hub_updateHoldingValuation_clamped(true);

        shortcut_mint_sync(0, 10113300624483719658505168383208138);

        // check if vault is async
        console2.log("is async: ", Helpers.isAsyncVault(address(_getVault())));

        asyncVault_maxMint(0, 0, 0);
    }

    /// === Categorized Issues === ///
    // forge test --match-test test_asyncVault_maxMint_2 -vvv
    // TODO: come back to this to refactor inline checks
    function test_asyncVault_maxMint_2() public {
        shortcut_deployNewTokenPoolAndShare(1, 1, true, false, false, false);

        shortcut_deposit_sync(0, 1000344664829076477032757366550618);

        asyncVault_maxMint(0, 0, 0);
    }

    // forge test --match-test test_doomsday_zeroPrice_noPanics_3 -vvv
    // NOTE: doesn't return 0 for maxDeposit if there's a nonzero maxReserve set
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/3
    function test_doomsday_zeroPrice_noPanics_3() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        doomsday_zeroPrice_noPanics();
    }

    // forge test --match-test test_asyncVault_maxDeposit_1 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/4
    function test_asyncVault_maxDeposit_1() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        hub_updateHoldingValuation_clamped(true);

        shortcut_mint_sync(10, 10112129893619390379128678749327912);

        shortcut_queue_redemption(
            1,
            8842148328038016815231732,
            1032506440027076166413381894971835202787810407249498930384303114617337
        );

        asyncVault_maxDeposit(0, 0, 2);
    }

    // forge test --match-test test_property_authorizationBoundaryEnforcement_17 -vvv
    // TODO: figure out solution for this, either remove call to _trackAuthorization entirely or adjust it to track manager permissions in call to hub_createAccount
    function test_property_authorizationBoundaryEnforcement_17() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        balanceSheet_deny();

        hub_createAccount(0, false);

        property_authorizationBoundaryEnforcement();
    }
}
