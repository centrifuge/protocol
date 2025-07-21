// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {LinkShareTokenCommon} from "./LinkShareTokenCommon.sol";

/// @notice Unified Ethereum spell that transitions both JTRSY and JAAA to V3 control and links them
/// @dev This spell requires to be relied both on V2 as well as V3 roots via the corresponding guardians
contract LinkShareTokenEth is LinkShareTokenCommon {
    // JAAA configuration (only exists on Ethereum)
    PoolId public constant JAAA_POOL_ID = PoolId.wrap(281474976710663);
    ShareClassId public constant JAAA_SHARE_CLASS_ID = ShareClassId.wrap(0x00010000000000070000000000000001);
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    function execute() internal override {
        // Grant V3 permissions on JAAA share token (uses V2 Root permissions)
        V2_ROOT.relyContract(address(JAAA_SHARE_TOKEN), address(V3_ROOT));
        V2_ROOT.relyContract(address(JAAA_SHARE_TOKEN), V3_BALANCE_SHEET);
        V2_ROOT.relyContract(address(JAAA_SHARE_TOKEN), address(V3_SPOKE));

        // Link JAAA share token to V3 system (uses V3 Root permissions)
        V3_ROOT.relyContract(address(V3_SPOKE), address(this));
        V3_SPOKE.linkToken(JAAA_POOL_ID, JAAA_SHARE_CLASS_ID, JAAA_SHARE_TOKEN);
        V3_ROOT.denyContract(address(V3_SPOKE), address(this));

        // Handle JTRSY (from parent)
        super.execute();
    }
}
