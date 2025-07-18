// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

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

/// @notice V3 spell that links V2 share tokens to V3 system
/// @dev This spell runs on V3 Guardian/Root and performs V3 operations
contract LinkShareTokenCommon {
    bool public done;
    string public constant description = "Link V2 share tokens to V3 system";

    ISpoke public constant SPOKE = ISpoke(0xd30Da1d7F964E5f6C2D9fE2AAA97517F6B23FA2B);
    IRoot public constant ROOT = IRoot(0x7Ed48C31f2fdC40d37407cBaBf0870B2b688368f);

    // See https://www.notion.so/Centrifuge-V3-Initi-Pool-Setup-2322eac24e1780fa84acceaa1ff01dbf
    PoolId public constant JTRSY_POOL_ID = PoolId.wrap(281474976710662);
    ShareClassId public constant JTRSY_SHARE_CLASS_ID = ShareClassId.wrap(0x97aa65f23e7be09fcd62d0554d2e9273);
    IShareToken public constant JTRSY_SHARE_TOKEN = IShareToken(0x8c213ee79581Ff4984583C6a801e5263418C4b86);

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal virtual {
        // Link JTRSY share token to V3 system
        ROOT.relyContract(address(SPOKE), address(this));
        SPOKE.linkToken(JTRSY_POOL_ID, JTRSY_SHARE_CLASS_ID, JTRSY_SHARE_TOKEN);
        ROOT.denyContract(address(SPOKE), address(this));
    }
}
