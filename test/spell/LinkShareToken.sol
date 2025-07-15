// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {ISpoke} from "src/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

struct LinkShareTokenParams {
    PoolId poolId;
    ShareClassId shareClassId;
    IShareToken shareToken;
}

/// @title  LinkShareToken
/// @notice Spell to link existing V2 share tokens to the V3 system
contract LinkShareToken {
    bool public done;
    string public constant description = "Link V2 share tokens to V3 system";

    ISpoke public immutable spoke;

    LinkShareTokenParams public jtrsy;
    LinkShareTokenParams public jaaa;

    constructor(ISpoke spoke_, LinkShareTokenParams memory jtrsy_, LinkShareTokenParams memory jaaa_) {
        spoke = spoke_;
        jtrsy = jtrsy_;
        jaaa = jaaa_;
    }

    function cast() external {
        require(!done, "spell-already-cast");
        done = true;
        execute();
    }

    function execute() internal {
        spoke.linkToken(jtrsy.poolId, jtrsy.shareClassId, jtrsy.shareToken);
        if (!jaaa.poolId.isNull()) {
            spoke.linkToken(jaaa.poolId, jaaa.shareClassId, jaaa.shareToken);
        }
    }
}
