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
}
