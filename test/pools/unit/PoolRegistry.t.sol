// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";

import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {PoolId, newPoolId} from "src/pools/types/PoolId.sol";
import {AssetId} from "src/pools/types/AssetId.sol";
import {ShareClassId} from "src/pools/types/ShareClassId.sol";
import {PoolRegistry} from "src/pools/PoolRegistry.sol";
import {IPoolRegistry} from "src/pools/interfaces/IPoolRegistry.sol";
import {IShareClassManager} from "src/pools/interfaces/IShareClassManager.sol";

contract PoolRegistryTest is Test {
    using MathLib for uint256;

    PoolRegistry registry;

    uint16 constant CENTRIFUGE_CHAIN_ID = 23;
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
        registry = new PoolRegistry(address(this));
    }

    function testPoolRegistration(address fundAdmin) public nonZero(fundAdmin) notThisContract(fundAdmin) {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.registerPool(address(this), CENTRIFUGE_CHAIN_ID, USD, shareClassManager);

        vm.expectRevert(IPoolRegistry.EmptyShareClassManager.selector);
        registry.registerPool(address(this), CENTRIFUGE_CHAIN_ID, USD, IShareClassManager(address(0)));

        vm.expectRevert(IPoolRegistry.EmptyAdmin.selector);
        registry.registerPool(address(0), CENTRIFUGE_CHAIN_ID, USD, shareClassManager);

        vm.expectRevert(IPoolRegistry.EmptyCurrency.selector);
        registry.registerPool(address(this), CENTRIFUGE_CHAIN_ID, AssetId.wrap(0), shareClassManager);

        vm.expectEmit();
        emit IPoolRegistry.NewPool(newPoolId(CENTRIFUGE_CHAIN_ID, 1), fundAdmin, shareClassManager, USD);
        PoolId poolId = registry.registerPool(fundAdmin, CENTRIFUGE_CHAIN_ID, USD, shareClassManager);

        assertEq(poolId.chainId(), CENTRIFUGE_CHAIN_ID);
        assertEq(poolId.raw(), newPoolId(CENTRIFUGE_CHAIN_ID, 1).raw());
        assertEq(registry.latestId(), 1);

        assertTrue(registry.isAdmin(poolId, fundAdmin));
        assertFalse(registry.isAdmin(poolId, address(this)));
        assertEq(address(registry.shareClassManager(poolId)), address(shareClassManager));
    }

    function testUpdateAdmin(address fundAdmin, address additionalAdmin)
        public
        nonZero(fundAdmin)
        nonZero(additionalAdmin)
        notThisContract(fundAdmin)
        notThisContract(additionalAdmin)
    {
        vm.assume(fundAdmin != additionalAdmin);
        PoolId poolId = registry.registerPool(fundAdmin, CENTRIFUGE_CHAIN_ID, USD, shareClassManager);

        assertFalse(registry.isAdmin(poolId, additionalAdmin));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateAdmin(poolId, additionalAdmin, true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateAdmin(nonExistingPool, additionalAdmin, true);

        vm.expectRevert(IPoolRegistry.EmptyAdmin.selector);
        registry.updateAdmin(poolId, address(0), true);

        // Approve a new admin
        vm.expectEmit();
        emit IPoolRegistry.UpdatedAdmin(poolId, additionalAdmin, true);
        registry.updateAdmin(poolId, additionalAdmin, true);
        assertTrue(registry.isAdmin(poolId, additionalAdmin));

        // Remove an existing admin
        vm.expectEmit();
        emit IPoolRegistry.UpdatedAdmin(poolId, additionalAdmin, false);
        registry.updateAdmin(poolId, additionalAdmin, false);
        assertFalse(registry.isAdmin(poolId, additionalAdmin));
    }

    function testSetMetadata(bytes calldata metadata) public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, CENTRIFUGE_CHAIN_ID, USD, shareClassManager);

        assertEq(registry.metadata(poolId).length, 0);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setMetadata(poolId, metadata);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.setMetadata(nonExistingPool, metadata);

        vm.expectEmit();
        emit IPoolRegistry.SetMetadata(poolId, metadata);
        registry.setMetadata(poolId, metadata);
        assertEq(registry.metadata(poolId), metadata);
    }

    function testUpdateShareClassManager(IShareClassManager shareClassManager_)
        public
        nonZero(address(shareClassManager_))
    {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, CENTRIFUGE_CHAIN_ID, USD, shareClassManager);

        assertEq(address(registry.shareClassManager(poolId)), address(shareClassManager));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateShareClassManager(poolId, shareClassManager_);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateShareClassManager(nonExistingPool, shareClassManager_);

        vm.expectRevert(IPoolRegistry.EmptyShareClassManager.selector);
        registry.updateShareClassManager(poolId, IShareClassManager(address(0)));

        vm.expectEmit();
        emit IPoolRegistry.UpdatedShareClassManager(poolId, shareClassManager_);
        registry.updateShareClassManager(poolId, shareClassManager_);
        assertEq(address(registry.shareClassManager(poolId)), address(shareClassManager_));
    }

    function testUpdateCurrency(AssetId currency) public nonZero(currency.addr()) {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, CENTRIFUGE_CHAIN_ID, USD, shareClassManager);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateCurrency(poolId, currency);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateCurrency(nonExistingPool, currency);

        vm.expectRevert(IPoolRegistry.EmptyCurrency.selector);
        registry.updateCurrency(poolId, AssetId.wrap(0));

        vm.assume(AssetId.unwrap(registry.currency(poolId)) != AssetId.unwrap(currency));
        vm.expectEmit();
        emit IPoolRegistry.UpdatedCurrency(poolId, currency);
        registry.updateCurrency(poolId, currency);
        assertEq(AssetId.unwrap(registry.currency(poolId)), AssetId.unwrap(currency));
    }

    function testExists() public {
        PoolId poolId = registry.registerPool(makeAddr("fundManager"), CENTRIFUGE_CHAIN_ID, USD, shareClassManager);
        assertEq(registry.exists(poolId), true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        assertEq(registry.exists(nonExistingPool), false);
    }
}
