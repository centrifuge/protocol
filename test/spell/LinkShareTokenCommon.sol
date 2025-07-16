// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

struct LinkShareTokenParams {
    PoolId poolId;
    ShareClassId shareClassId;
    IShareToken shareToken;
}

/// @title  LinkShareTokenCommon
/// @notice Base contract with common JTRSY configuration for all networks
contract LinkShareTokenCommon {
    bool public done;
    string public constant description = "Link V2 share tokens to V3 system";

    ISpoke public constant SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);

    address public constant ROOT_ADDRESS = 0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f;
    address public constant BALANCE_SHEET_ADDRESS = 0xBcC8D02d409e439D98453C0b1ffa398dFFb31fda;

    PoolId public constant JTRSY_POOL_ID = PoolId.wrap(4139607887);
    ShareClassId public constant JTRSY_SHARE_CLASS_ID = ShareClassId.wrap(0x97aa65f23e7be09fcd62d0554d2e9273);
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        SPOKE.linkToken(JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID, JTRSY_SHARE_TOKEN);

        IAuth(address(JTRSY_SHARE_TOKEN)).rely(ROOT_ADDRESS);
        IAuth(address(JTRSY_SHARE_TOKEN)).rely(BALANCE_SHEET_ADDRESS);
        IAuth(address(JTRSY_SHARE_TOKEN)).rely(address(SPOKE));
    }
}
