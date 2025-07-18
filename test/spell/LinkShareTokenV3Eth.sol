// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {LinkShareTokenCommon} from "./LinkShareTokenCommon.sol";

/// @notice V3 Ethereum-specific spell that links both JTRSY and JAAA share tokens to V3 system
/// @dev This spell runs on V3 Guardian/Root and performs V3 operations
contract LinkShareTokenEth is LinkShareTokenCommon {
    // See https://www.notion.so/Centrifuge-V3-Initi-Pool-Setup-2322eac24e1780fa84acceaa1ff01dbf
    PoolId public constant JAAA_POOL_ID = PoolId.wrap(281474976710663);
    ShareClassId public constant JAAA_SHARE_CLASS_ID = ShareClassId.wrap(0x57e1b211a9ce6306b69a414f274f9998);
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    function execute() internal override {
        // Link JTRSY share token (from parent)
        super.execute();

        // Link JAAA share token to V3 system (Ethereum only)
        ROOT.relyContract(address(SPOKE), address(this));
        SPOKE.linkToken(JAAA_POOL_ID, JAAA_SHARE_CLASS_ID, JAAA_SHARE_TOKEN);
        ROOT.denyContract(address(SPOKE), address(this));
    }
}
