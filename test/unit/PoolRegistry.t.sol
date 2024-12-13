// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PoolId} from "src/types/PoolId.sol";
import {PoolRegistry} from "src/PoolRegistry.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {IERC20Metadata} from "src/interfaces/IERC20Metadata.sol";
import {IShareClassManager} from "src/interfaces/IShareClassManager.sol";

contract PoolRegistryTest is Test {
    using MathLib for uint256;

    PoolRegistry registry;
    IERC20Metadata USD = IERC20Metadata(address(840));
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
        registry.registerPool(address(this), IERC20Metadata(address(0)), shareClassManager);

        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);
        assertEq(poolId.chainId(), block.chainid.toUint32());

        assertTrue(registry.poolAdmins(poolId, fundAdmin));
        assertFalse(registry.poolAdmins(poolId, address(this)));
        assertEq(address(registry.shareClassManagers(poolId)), address(shareClassManager));
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

        assertFalse(registry.poolAdmins(poolId, additionalAdmin));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateAdmin(poolId, additionalAdmin, true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateAdmin(nonExistingPool, additionalAdmin, true);

        vm.expectRevert(IPoolRegistry.EmptyAdmin.selector);
        registry.updateAdmin(poolId, address(0), true);

        // Approve a new admin
        registry.updateAdmin(poolId, additionalAdmin, true);
        assertTrue(registry.poolAdmins(poolId, additionalAdmin));

        // Remove an existing admin
        registry.updateAdmin(poolId, additionalAdmin, false);
        assertFalse(registry.poolAdmins(poolId, additionalAdmin));
    }

    function testUpdateMetadata(bytes calldata metadata) public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

        assertEq(registry.metadata(poolId).length, 0);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateMetadata(poolId, metadata);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateMetadata(nonExistingPool, metadata);

        registry.updateMetadata(poolId, metadata);
        assertEq(registry.metadata(poolId), metadata);
    }

    function testUpdateShareClassManager(IShareClassManager shareClassManager_)
        public
        nonZero(address(shareClassManager_))
    {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

        assertEq(address(registry.shareClassManagers(poolId)), address(shareClassManager));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateShareClassManager(poolId, shareClassManager_);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateShareClassManager(nonExistingPool, shareClassManager_);

        vm.expectRevert(IPoolRegistry.EmptyShareClassManager.selector);
        registry.updateShareClassManager(poolId, IShareClassManager(address(0)));

        registry.updateShareClassManager(poolId, shareClassManager_);
        assertEq(address(registry.shareClassManagers(poolId)), address(shareClassManager_));
    }

    function testUpdatePoolCurrency(IERC20Metadata currency) public nonZero(address(currency)) {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, USD, shareClassManager);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateCurrency(poolId, currency);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateCurrency(nonExistingPool, currency);

        vm.expectRevert(IPoolRegistry.EmptyCurrency.selector);
        registry.updateCurrency(poolId, IERC20Metadata(address(0)));

        vm.assume(address(registry.poolCurrencies(poolId)) != address(currency));
        registry.updateCurrency(poolId, currency);
        assertEq(address(registry.poolCurrencies(poolId)), address(currency));
    }

    function testSetAddressFor() public {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setAddressFor(PoolId.wrap(1), "key", address(1));

        registry.setAddressFor(PoolId.wrap(1), "key", address(1));
        assertEq(address(registry.addressFor(PoolId.wrap(1), "key")), address(1));
    }
}
