// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PoolId, PoolIdLib} from "src/types/PoolId.sol";
import {AssetId} from "src/types/AssetId.sol";
import {PoolRegistry} from "src/PoolRegistry.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";

contract PoolRegistryTest is Test {
    using MathLib for uint256;

    PoolRegistry registry;
    AssetId USD = AssetId.wrap(840);
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
        registry.registerPool(address(this), USD, shareClassManager);

        vm.expectRevert(IPoolRegistry.EmptyShareClassManager.selector);
        registry.registerPool(address(this), USD, IShareClassManager(address(0)));

        vm.expectRevert(IPoolRegistry.EmptyAdmin.selector);
        registry.registerPool(address(0), USD, shareClassManager);

        vm.expectRevert(IPoolRegistry.EmptyCurrency.selector);
        registry.registerPool(address(this), AssetId.wrap(0), shareClassManager);

        vm.expectEmit();
        emit IPoolRegistry.NewPool(PoolIdLib.newFrom(1), fundAdmin, shareClassManager, USD);
        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

        assertEq(poolId.chainId(), block.chainid.toUint32());
        assertEq(PoolId.unwrap(poolId), ((uint64(block.chainid.toUint32()) << 32) | 1));
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
        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

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

    function testAllowInvestorAsset(address fundAdmin) public nonZero(fundAdmin) notThisContract(fundAdmin) {
        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

        AssetId validAsset = AssetId.wrap(1);
        assertFalse(registry.isInvestorAssetAllowed(poolId, validAsset));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.allowInvestorAsset(poolId, validAsset, true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.allowInvestorAsset(nonExistingPool, validAsset, true);

        vm.expectRevert(IPoolRegistry.EmptyAsset.selector);
        registry.allowInvestorAsset(poolId, AssetId.wrap(0), true);

        // Allow an asset
        vm.expectEmit();
        emit IPoolRegistry.AllowedInvestorAsset(poolId, validAsset, true);
        registry.allowInvestorAsset(poolId, validAsset, true);
        assertTrue(registry.isInvestorAssetAllowed(poolId, validAsset));

        // Disallow an asset
        vm.expectEmit();
        emit IPoolRegistry.AllowedInvestorAsset(poolId, validAsset, false);
        registry.allowInvestorAsset(poolId, validAsset, false);
        assertFalse(registry.isInvestorAssetAllowed(poolId, validAsset));
    }

    function testSetMetadata(bytes calldata metadata) public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

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

        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

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

        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

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
        PoolId poolId = registry.registerPool(makeAddr("fundManager"), USD, shareClassManager);
        assertEq(registry.exists(poolId), true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        assertEq(registry.exists(nonExistingPool), false);
    }
}
