// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId, newPoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {IHubRegistry} from "src/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

contract HubRegistryTest is Test {
    using MathLib for uint256;

    HubRegistry registry;

    uint16 constant CENTRIFUGE_ID = 23;
    AssetId constant USD = AssetId.wrap(840);
    ShareClassId constant SC_A = ShareClassId.wrap(bytes16("sc"));
    PoolId constant POOL_A = PoolId.wrap(33);
    PoolId constant POOL_B = PoolId.wrap(44);

    IShareClassManager shareClassManager = IShareClassManager(makeAddr("shareClassManager"));

    modifier nonZero(address addr) {
        vm.assume(addr != address(0));
        _;
    }

    modifier notThisContract(address addr) {
        vm.assume(address(this) != addr);
        _;
    }

    function setUp() public {
        registry = new HubRegistry(address(this));
    }

    function testPoolRegistration(address fundAdmin) public nonZero(fundAdmin) notThisContract(fundAdmin) {
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.registerPool(poolId, address(this), USD);

        vm.expectRevert(IHubRegistry.EmptyAccount.selector);
        registry.registerPool(poolId, address(0), USD);

        vm.expectRevert(IHubRegistry.EmptyCurrency.selector);
        registry.registerPool(poolId, address(this), AssetId.wrap(0));

        vm.expectEmit();
        emit IHubRegistry.NewPool(newPoolId(CENTRIFUGE_ID, 1), fundAdmin, USD);
        registry.registerPool(poolId, fundAdmin, USD);

        assertEq(poolId.centrifugeId(), CENTRIFUGE_ID);
        assertEq(poolId.raw(), newPoolId(CENTRIFUGE_ID, 1).raw());

        assertTrue(registry.manager(poolId, fundAdmin));
        assertFalse(registry.manager(poolId, address(this)));
    }

    function testUpdateManager(address fundAdmin, address additionalAdmin)
        public
        nonZero(fundAdmin)
        nonZero(additionalAdmin)
        notThisContract(fundAdmin)
        notThisContract(additionalAdmin)
    {
        vm.assume(fundAdmin != additionalAdmin);
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        assertFalse(registry.manager(poolId, additionalAdmin));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateManager(poolId, additionalAdmin, true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IHubRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateManager(nonExistingPool, additionalAdmin, true);

        vm.expectRevert(IHubRegistry.EmptyAccount.selector);
        registry.updateManager(poolId, address(0), true);

        // Approve a new admin
        vm.expectEmit();
        emit IHubRegistry.UpdateManager(poolId, additionalAdmin, true);
        registry.updateManager(poolId, additionalAdmin, true);
        assertTrue(registry.manager(poolId, additionalAdmin));

        // Remove an existing admin
        vm.expectEmit();
        emit IHubRegistry.UpdateManager(poolId, additionalAdmin, false);
        registry.updateManager(poolId, additionalAdmin, false);
        assertFalse(registry.manager(poolId, additionalAdmin));
    }

    function testSetMetadata(bytes calldata metadata) public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        assertEq(registry.metadata(poolId).length, 0);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setMetadata(poolId, metadata);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IHubRegistry.NonExistingPool.selector, nonExistingPool));
        registry.setMetadata(nonExistingPool, metadata);

        vm.expectEmit();
        emit IHubRegistry.SetMetadata(poolId, metadata);
        registry.setMetadata(poolId, metadata);
        assertEq(registry.metadata(poolId), metadata);
    }

    function testUpdateDependency(bytes32 what, address dependency) public nonZero(dependency) {
        assertEq(address(registry.dependency(what)), address(0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateDependency(what, dependency);

        vm.expectEmit();
        emit IHubRegistry.UpdateDependency(what, dependency);
        registry.updateDependency(what, dependency);
        assertEq(address(registry.dependency(what)), address(dependency));
    }

    function testUpdateCurrency(AssetId currency) public nonZero(currency.addr()) {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateCurrency(poolId, currency);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IHubRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateCurrency(nonExistingPool, currency);

        vm.expectRevert(IHubRegistry.EmptyCurrency.selector);
        registry.updateCurrency(poolId, AssetId.wrap(0));

        vm.assume(AssetId.unwrap(registry.currency(poolId)) != AssetId.unwrap(currency));
        vm.expectEmit();
        emit IHubRegistry.UpdateCurrency(poolId, currency);
        registry.updateCurrency(poolId, currency);
        assertEq(AssetId.unwrap(registry.currency(poolId)), AssetId.unwrap(currency));
    }

    function testExists() public {
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundManager"), USD);
        assertEq(registry.exists(poolId), true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        assertEq(registry.exists(nonExistingPool), false);
    }
}
