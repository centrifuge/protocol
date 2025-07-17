// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {LinkShareTokenCommon} from "./LinkShareTokenCommon.sol";

/// @notice Ethereum-specific spell that links both JTRSY_USDC and JAAA_USDC
contract LinkShareTokenEth is LinkShareTokenCommon {
    // See https://www.notion.so/Centrifuge-V3-Initi-Pool-Setup-2322eac24e1780fa84acceaa1ff01dbf
    PoolId public constant JAAA_POOL_ID = PoolId.wrap(281474976710663);
    ShareClassId public constant JAAA_SHARE_CLASS_ID = ShareClassId.wrap(0x57e1b211a9ce6306b69a414f274f9998);
    IShareToken public constant JAAA_SHARE_TOKEN = IShareToken(0x5a0F93D040De44e78F251b03c43be9CF317Dcf64);

    function execute() internal override {
        // Link JTRSY and grant permissions
        super.execute();

        // Link JAAA and grant permissions
        SPOKE.linkToken(JAAA_POOL_ID, JAAA_SHARE_CLASS_ID, JAAA_SHARE_TOKEN);
        IAuth(address(JAAA_SHARE_TOKEN)).rely(ROOT_ADDRESS);
        IAuth(address(JAAA_SHARE_TOKEN)).rely(BALANCE_SHEET_ADDRESS);
        IAuth(address(JAAA_SHARE_TOKEN)).rely(address(SPOKE));
    }
}
