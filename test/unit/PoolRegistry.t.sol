// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PoolId} from "src/types/PoolId.sol";
import {Currency} from "src/types/Currency.sol";
import {PoolRegistry} from "src/PoolRegistry.sol";
import {IPoolRegistry} from "src/interfaces/IPoolRegistry.sol";
import {IAuth} from "src/interfaces/IAuth.sol";
import {FiatCurrencyRegistry} from "src/FiatCurrencyRegistry.sol";

contract PoolRegistryTest is Test {
    using MathLib for uint256;

    PoolRegistry registry;
    FiatCurrencyRegistry fiatRegistry;
    Currency USD = Currency(address(840), 18, "USD", "USD");
    address shareClassManager = makeAddr("shareClassManager");

    modifier nonZero(address addr) {
        vm.assume(addr != address(0));
        _;
    }

    modifier notThisContract(address addr) {
        vm.assume(address(this) != addr);
        _;
    }

    function setUp() public {
        fiatRegistry = new FiatCurrencyRegistry();
        registry = new PoolRegistry(address(this), address(fiatRegistry));

        fiatRegistry.register(USD);
    }

    function testAuthorization(address additionalWard) public nonZero(additionalWard) notThisContract(additionalWard) {
        assertEq(registry.wards(address(this)), 1);

        assertEq(registry.wards(additionalWard), 0);
        registry.rely(additionalWard);
        assertEq(registry.wards(additionalWard), 1);

        registry.deny(additionalWard);
        assertEq(registry.wards(additionalWard), 0);
    }

    function testPoolRegistration(address fundAdmin) public nonZero(fundAdmin) notThisContract(fundAdmin) {
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.registerPool(address(this), USD.addr, shareClassManager);

        vm.expectRevert(IPoolRegistry.EmptyShareClassManager.selector);
        registry.registerPool(address(this), USD.addr, address(0));

        vm.expectRevert(IPoolRegistry.EmptyAdmin.selector);
        registry.registerPool(address(0), USD.addr, shareClassManager);

        vm.expectRevert(IPoolRegistry.EmptyCurrency.selector);
        registry.registerPool(address(this), address(0), shareClassManager);

        PoolId poolId = registry.registerPool(fundAdmin, USD.addr, shareClassManager);
        assertEq(poolId.chainId(), block.chainid.toUint32());

        assertTrue(registry.poolAdmins(poolId, fundAdmin));
        assertFalse(registry.poolAdmins(poolId, address(this)));
        assertEq(registry.shareClassManagers(poolId), shareClassManager);
    }

    function testUpdateAdmin(address fundAdmin, address additionalAdmin)
        public
        nonZero(fundAdmin)
        nonZero(additionalAdmin)
        notThisContract(fundAdmin)
        notThisContract(additionalAdmin)
    {
        vm.assume(fundAdmin != additionalAdmin);
        PoolId poolId = registry.registerPool(fundAdmin, USD.addr, shareClassManager);

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

        PoolId poolId = registry.registerPool(fundAdmin, USD.addr, shareClassManager);

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

    function testUpdateShareClassManager(address shareClassManager_) public nonZero(shareClassManager_) {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.registerPool(fundAdmin, USD.addr, shareClassManager);

        assertEq(registry.shareClassManagers(poolId), shareClassManager);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateShareClassManager(poolId, shareClassManager_);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateShareClassManager(nonExistingPool, shareClassManager_);

        vm.expectRevert(IPoolRegistry.EmptyShareClassManager.selector);
        registry.updateShareClassManager(poolId, address(0));

        registry.updateShareClassManager(poolId, shareClassManager_);
        assertEq(registry.shareClassManagers(poolId), shareClassManager_);
    }

    function testUpdatePoolCurrency(address currency_) public nonZero(currency_) {
        address fundAdmin = makeAddr("fundAdmin");
        Currency memory currency = Currency(currency_, 18, "TEST", "TEST");
        fiatRegistry.register(currency);

        PoolId poolId = registry.registerPool(fundAdmin, USD.addr, shareClassManager);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateCurrency(poolId, currency_);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IPoolRegistry.NonExistingPool.selector, nonExistingPool));
        registry.updateCurrency(nonExistingPool, currency_);

        vm.expectRevert(IPoolRegistry.EmptyCurrency.selector);
        registry.updateCurrency(poolId, address(0));

        registry.updateCurrency(poolId, currency.addr);
        (address poolCurrencyAddr,,,) = registry.poolCurrencies(poolId);
        assertEq(poolCurrencyAddr, currency.addr);
    }
}
