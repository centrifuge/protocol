// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {HubRegistry} from "../../../../src/core/hub/HubRegistry.sol";
import {PoolId, newPoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IManifest} from "../../../../src/core/hub/interfaces/IManifest.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

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

    function testSetManifest() public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        IManifest manifest = IManifest(makeAddr("manifest"));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setManifest(poolId, manifest);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(abi.encodeWithSelector(IHubRegistry.NonExistingPool.selector, nonExistingPool));
        registry.setManifest(nonExistingPool, manifest);

        vm.expectEmit();
        emit IHubRegistry.SetManifest(poolId, manifest);
        registry.setManifest(poolId, manifest);
        assertEq(address(registry.manifest(poolId)), address(manifest));
    }

    function testAuthorizeRevertsWithoutManifest(bytes calldata data) public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        // authorize is ward-only; the manager check lives in Hub.initiateAuthorization.
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.initiateAuthorization(poolId, fundAdmin, data);

        // No manifest set for the pool, so authorize cannot classify the call.
        vm.expectRevert(IHubRegistry.NoManifest.selector);
        registry.initiateAuthorization(poolId, fundAdmin, data);
    }

    function testConsumeAuthorizationOnlyCallableByManifest(address caller, bytes calldata data, uint48 expiry) public {
        address fundAdmin = makeAddr("fundAdmin");
        IManifest manifest = IManifest(makeAddr("manifest"));

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);
        registry.setManifest(poolId, manifest);

        // Caller is address(this), not the pool's manifest.
        vm.expectRevert(IHubRegistry.NotManifest.selector);
        registry.consumeAuthorization(poolId, caller, data, expiry);
    }

    function testUpdateDependency(bytes32 what, address dependency) public nonZero(dependency) {
        // First register asset and pool to use for dependency testing
        registry.registerAsset(USD, 18);
        registry.registerPool(POOL_A, address(this), USD);

        assertEq(address(registry.dependency(POOL_A, what)), address(0));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateDependency(POOL_A, what, dependency);

        vm.expectEmit();
        emit IHubRegistry.UpdateDependency(POOL_A, what, dependency);
        registry.updateDependency(POOL_A, what, dependency);
        assertEq(address(registry.dependency(POOL_A, what)), address(dependency));
    }

    function testUpdateCurrency(AssetId currency) public nonZero(address(uint160(currency.raw()))) {
        address fundAdmin = makeAddr("fundAdmin");

        registry.registerAsset(USD, 6);
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

        // Same decimals as the incumbent (USD, 6) so the decimals-mismatch guard permits the swap.
        registry.registerAsset(currency, 6);

        vm.expectEmit();
        emit IHubRegistry.UpdateCurrency(poolId, currency);
        registry.updateCurrency(poolId, currency);
        assertEq(AssetId.unwrap(registry.currency(poolId)), AssetId.unwrap(currency));
    }

    function testUpdateCurrencyRevertsOnUnregisteredCurrency() public {
        address fundAdmin = makeAddr("fundAdmin");

        registry.registerAsset(USD, 6);
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        AssetId unregisteredCurrency = AssetId.wrap(978);
        assertFalse(registry.isRegistered(unregisteredCurrency));

        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        registry.updateCurrency(poolId, unregisteredCurrency);
        assertEq(AssetId.unwrap(registry.currency(poolId)), AssetId.unwrap(USD));
    }

    function testExists() public {
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundManager"), USD);
        assertEq(registry.exists(poolId), true);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        assertEq(registry.exists(nonExistingPool), false);
    }

    function testRegisterAsset(uint8 decimals) public {
        assertFalse(registry.isRegistered(USD));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.registerAsset(USD, decimals);

        vm.expectEmit();
        emit IHubRegistry.NewAsset(USD, decimals);
        registry.registerAsset(USD, decimals);

        assertTrue(registry.isRegistered(USD));
        assertEq(registry.decimals(USD), decimals);
        assertEq(registry.decimals(uint256(AssetId.unwrap(USD))), decimals);

        (bool registered, uint8 assetDecimals) = registry.asset(USD);
        assertTrue(registered);
        assertEq(assetDecimals, decimals);
    }

    function testAssetGetter() public {
        AssetId unregistered = AssetId.wrap(978);

        // Unregistered asset reads as (false, 0), not a revert.
        (bool registered, uint8 assetDecimals) = registry.asset(unregistered);
        assertFalse(registered);
        assertEq(assetDecimals, 0);

        registry.registerAsset(USD, 6);

        (registered, assetDecimals) = registry.asset(USD);
        assertTrue(registered);
        assertEq(assetDecimals, 6);
    }

    function testRegisterAssetZeroDecimals() public {
        assertFalse(registry.isRegistered(USD));

        registry.registerAsset(USD, 0);

        // A 0-decimal asset is registered, not conflated with "not registered".
        assertTrue(registry.isRegistered(USD));
        assertEq(registry.decimals(USD), 0);
        assertEq(registry.decimals(uint256(AssetId.unwrap(USD))), 0);

        // And usable as a pool currency, whose decimals(PoolId) getter returns 0.
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundAdmin"), USD);
        assertEq(registry.decimals(poolId), 0);
    }

    function testRegisterAssetRevertsOnDuplicate() public {
        registry.registerAsset(USD, 6);

        vm.expectRevert(IHubRegistry.AssetAlreadyRegistered.selector);
        registry.registerAsset(USD, 6);

        // A different decimals value does not change the outcome: still reverts, no overwrite.
        vm.expectRevert(IHubRegistry.AssetAlreadyRegistered.selector);
        registry.registerAsset(USD, 18);

        assertEq(registry.decimals(USD), 6);
    }

    function testRegisterAssetZeroDecimalsRevertsOnDuplicate() public {
        registry.registerAsset(USD, 0);

        // The registered flag, not the decimals value, gates re-registration.
        vm.expectRevert(IHubRegistry.AssetAlreadyRegistered.selector);
        registry.registerAsset(USD, 0);
    }

    function testDecimalsRevertsOnUnregistered() public {
        AssetId unregistered = AssetId.wrap(978);

        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        registry.decimals(unregistered);

        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        registry.decimals(uint256(AssetId.unwrap(unregistered)));
    }

    function testUpdateCurrencyRevertsOnDecimalsMismatch() public {
        registry.registerAsset(USD, 6); // incumbent pool currency: 6 decimals
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundAdmin"), USD);

        // A coarser (0-dec) currency: rejected, pool decimals must stay 6 to match deployed share tokens.
        AssetId zeroDecCurrency = AssetId.wrap(978);
        registry.registerAsset(zeroDecCurrency, 0);
        vm.expectRevert(IHubRegistry.CurrencyDecimalsMismatch.selector);
        registry.updateCurrency(poolId, zeroDecCurrency);

        AssetId eighteenDecCurrency = AssetId.wrap(979);
        registry.registerAsset(eighteenDecCurrency, 18);
        vm.expectRevert(IHubRegistry.CurrencyDecimalsMismatch.selector);
        registry.updateCurrency(poolId, eighteenDecCurrency);

        // Currency unchanged after both rejected swaps.
        assertEq(AssetId.unwrap(registry.currency(poolId)), AssetId.unwrap(USD));
        assertEq(registry.decimals(poolId), 6);
    }

    function testUpdateCurrencySameDecimalsDifferentAsset() public {
        registry.registerAsset(USD, 6);
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundAdmin"), USD);

        // A different asset with the same 6 decimals: the swap is permitted and pool decimals stay 6.
        AssetId sameDecCurrency = AssetId.wrap(978);
        registry.registerAsset(sameDecCurrency, 6);

        vm.expectEmit();
        emit IHubRegistry.UpdateCurrency(poolId, sameDecCurrency);
        registry.updateCurrency(poolId, sameDecCurrency);

        assertEq(AssetId.unwrap(registry.currency(poolId)), AssetId.unwrap(sameDecCurrency));
        assertEq(registry.decimals(poolId), 6);
    }
}
