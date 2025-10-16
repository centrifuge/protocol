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

    // forge test --match-test test_asyncVault_maxMint_4 -vvv
    function test_asyncVault_maxMint_4() public {
        shortcut_deployNewTokenPoolAndShare(15, 1, true, false, false, false);

        shortcut_mint_sync(0, 1043787997448711703416);

        asyncVault_maxMint(0, 0, 0);
    }

    /// === Categorized Issues === ///

    // forge test --match-test test_doomsday_zeroPrice_noPanics_3 -vvv
    // NOTE: doesn't return 0 for maxDeposit if there's a nonzero maxReserve set
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/3
    function test_doomsday_zeroPrice_noPanics_3() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        doomsday_zeroPrice_noPanics();
    }

    // forge test --match-test test_asyncVault_maxDeposit_11 -vvv
    // NOTE: see issue here: https://github.com/Recon-Fuzz/centrifuge-invariants/issues/4
    // forge test --match-test test_asyncVault_maxDeposit_1 -vvv
    function test_asyncVault_maxDeposit_1() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        shortcut_deposit_sync(0, 0);

        hub_addShareClass(203001861288931809357260237786);

        asyncVault_maxDeposit(0, 2, 0);
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
}
