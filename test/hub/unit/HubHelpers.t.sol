// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {IHubMessageSender} from "../../../src/common/interfaces/IGatewaySenders.sol";

import {HubHelpers} from "../../../src/hub/HubHelpers.sol";
import {IHoldings} from "../../../src/hub/interfaces/IHoldings.sol";
import {IAccounting} from "../../../src/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "../../../src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../../src/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

contract TestCommon is Test {
    IHoldings immutable holdings = IHoldings(makeAddr("Holdings"));
    IAccounting immutable accounting = IAccounting(makeAddr("Accounting"));
    IHubRegistry immutable hubRegistry = IHubRegistry(makeAddr("HubRegistry"));
    IHubMessageSender immutable sender = IHubMessageSender(makeAddr("sender"));
    IShareClassManager immutable scm = IShareClassManager(makeAddr("ShareClassManager"));

    HubHelpers hubHelpers = new HubHelpers(holdings, accounting, hubRegistry, sender, scm, address(this));

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_A = ShareClassId.wrap("2");
    AssetId constant ASSET_A = AssetId.wrap(3);
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

        vm.expectRevert(IAuth.NotAuthorized.selector);
        hubHelpers.updateAccountingValue(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), true, 0);

        vm.stopPrank();
    }
}

contract TestPricePoolPerAsset is TestCommon {
    function testPriceWithoutHoldins() public {
        vm.mockCall(
            address(holdings),
            abi.encodeWithSelector(IHoldings.isInitialized.selector, POOL_A, SC_A, ASSET_A),
            abi.encode(false)
        );

        assertEq(hubHelpers.pricePoolPerAsset(POOL_A, SC_A, ASSET_A).raw(), d18(1, 1).raw());
    }
}
