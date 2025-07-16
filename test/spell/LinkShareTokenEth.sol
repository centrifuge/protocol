// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {LinkShareTokenCommon} from "./LinkShareTokenCommon.sol";

/// @title  LinkShareTokenEth
/// @notice Ethereum-specific spell that links both JTRSY and JAAA tokens
contract LinkShareTokenEth is LinkShareTokenCommon {
    PoolId public constant JAAA_POOL_ID = PoolId.wrap(158696445);
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
