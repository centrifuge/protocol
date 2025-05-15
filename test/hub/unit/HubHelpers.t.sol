// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IHoldings} from "src/hub/interfaces/IHoldings.sol";
import {IAccounting} from "src/hub/interfaces/IAccounting.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";
import {Hub} from "src/hub/Hub.sol";
import {HubHelpers} from "src/hub/HubHelpers.sol";

contract TestCommon is Test {
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));

    HubHelpers hubHelpers = new HubHelpers(holdings, accounting, hubRegistry, scm, address(this));
}

contract TestMainMethodsChecks is TestCommon {
    function testErrNotAuthotized() public {
        vm.startPrank(makeAddr("noWard"));

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHelpers.notifyDeposit(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), bytes32(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHelpers.notifyRedeem(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), bytes32(0), 0);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHelpers.updateAccountingAmount(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), true, 0);

        vm.stopPrank();
    }
}
