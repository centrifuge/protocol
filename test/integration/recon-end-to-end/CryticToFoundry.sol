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
    function test_doomsday_zeroPrice_noPanics_3() public {
        shortcut_deployNewTokenPoolAndShare(0, 1, false, false, false, false);

        doomsday_zeroPrice_noPanics();
    }
}
