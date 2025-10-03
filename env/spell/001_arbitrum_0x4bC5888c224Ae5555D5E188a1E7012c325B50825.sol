// Network: Arbitrum (Chain ID: 42161)
// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

struct LinkShareTokenParams {
    PoolId poolId;
    ShareClassId shareClassId;
    IShareToken shareToken;
}

/// @notice Unified spell that transitions V2 share tokens to V3 control and links them to V3 system
/// @dev This spell requires to be relied both on V2 as well as V3 roots via the corresponding guardians
contract LinkShareTokenCommon {
    bool public done;
    string public constant description = "Transition V2 share tokens to V3 control and link to V3 system";

    // V2 Root address (same across all networks)
    IRoot public constant V2_ROOT = IRoot(0x0C1fDfd6a1331a875EA013F3897fc8a76ada5DfC);

    // V3 addresses
    ISpoke public constant V3_SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    IRoot public constant V3_ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);
    address public constant V3_BALANCE_SHEET = 0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda;

    // JTRSY configuration (exists on all networks)
    PoolId public constant JTRSY_POOL_ID = PoolId.wrap(281474976710662);
    ShareClassId public constant JTRSY_SHARE_CLASS_ID = ShareClassId.wrap(0x00010000000000060000000000000001);
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        // Grant V3 permissions on V2 share tokens (uses V2 Root permissions)
        V2_ROOT.relyContract(address(JTRSY_SHARE_TOKEN), address(V3_ROOT));
        V2_ROOT.relyContract(address(JTRSY_SHARE_TOKEN), V3_BALANCE_SHEET);
        V2_ROOT.relyContract(address(JTRSY_SHARE_TOKEN), address(V3_SPOKE));

        // Link JTRSY share token to V3 system (uses V3 Root permissions)
        V3_ROOT.relyContract(address(V3_SPOKE), address(this));
        V3_SPOKE.linkToken(JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID, JTRSY_SHARE_TOKEN);
        V3_ROOT.denyContract(address(V3_SPOKE), address(this));

        // Deny permissions on V2 and V3 roots just to be safe
        IAuth(address(V2_ROOT)).deny(address(this));
        IAuth(address(V3_ROOT)).deny(address(this));
    }
}