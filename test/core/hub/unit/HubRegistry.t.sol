// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {HubRegistry} from "../../../../src/core/hub/HubRegistry.sol";
import {PoolId, newPoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IHubPolicy} from "../../../../src/core/utils/interfaces/IPolicy.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {IBridgingHook} from "../../../../src/core/hub/interfaces/IBridgingHook.sol";
import {IShareClassManager} from "../../../../src/core/hub/interfaces/IShareClassManager.sol";

import "forge-std/Test.sol";

contract HubRegistryTest is Test {
    using MathLib for uint256;

    HubRegistry registry;

    uint16 constant CENTRIFUGE_ID = 23;
    AssetId constant USD = AssetId.wrap(840);
    AssetId constant EUR = AssetId.wrap(978);
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
        registry.registerAsset(USD, 6);
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

        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        registry.registerPool(poolId, address(this), AssetId.wrap(979));

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
        vm.expectRevert(IHubRegistry.NonExistingPool.selector);
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
        vm.expectRevert(IHubRegistry.NonExistingPool.selector);
        registry.setMetadata(nonExistingPool, metadata);

        vm.expectEmit();
        emit IHubRegistry.SetMetadata(poolId, metadata);
        registry.setMetadata(poolId, metadata);
        assertEq(registry.metadata(poolId), metadata);
    }

    function testSetPolicy() public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        IHubPolicy policy = IHubPolicy(makeAddr("policy"));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setPolicy(poolId, policy);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(IHubRegistry.NonExistingPool.selector);
        registry.setPolicy(nonExistingPool, policy);

        vm.expectEmit();
        emit IHubRegistry.SetPolicy(poolId, policy);
        registry.setPolicy(poolId, policy);
        assertEq(address(registry.policy(poolId)), address(policy));
    }

    function testSetBridgingHook() public {
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundAdmin"), USD);

        IBridgingHook hook = IBridgingHook(makeAddr("bridgingHook"));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setBridgingHook(poolId, hook);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(IHubRegistry.NonExistingPool.selector);
        registry.setBridgingHook(nonExistingPool, hook);

        vm.expectEmit();
        emit IHubRegistry.SetBridgingHook(poolId, address(hook));
        registry.setBridgingHook(poolId, hook);
        assertEq(address(registry.bridgingHook(poolId)), address(hook));
    }

    function testPolicyReinstallChangesAuthId(bytes calldata data) public {
        IHubPolicy policy = IHubPolicy(makeAddr("policy"));

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundAdmin"), USD);
        registry.setPolicy(poolId, policy);
        assertEq(registry.policyNonce(poolId), 1);

        bytes32 id = registry.authId(poolId, data);

        // Re-installing the same policy address bumps the nonce, re-namespacing every id.
        registry.setPolicy(poolId, policy);
        assertEq(registry.policyNonce(poolId), 2);
        assertNotEq(registry.authId(poolId, data), id);
    }

    function testPolicySwapBackDoesNotResurrectAuthorization() public {
        address fundAdmin = makeAddr("fundAdmin");
        IHubPolicy policy = IHubPolicy(makeAddr("policy"));
        bytes memory data = "authorized calldata";

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);
        registry.setPolicy(poolId, policy);

        vm.mockCall(
            address(policy), abi.encodeWithSelector(IHubPolicy.authorizationDelay.selector), abi.encode(uint48(1 days))
        );
        registry.initiateAuthorization(poolId, fundAdmin, data);
        vm.warp(block.timestamp + 1 days);

        // Swap the policy away and back: the matured authorization must not be resurrected.
        registry.setPolicy(poolId, IHubPolicy(makeAddr("otherPolicy")));
        registry.setPolicy(poolId, policy);

        vm.prank(address(policy));
        vm.expectRevert(IHubRegistry.Unauthorized.selector);
        registry.consumeAuthorization(poolId, fundAdmin, data, 1 days);
    }

    function testAuthorizeRevertsWithoutPolicy(bytes calldata data) public {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        // authorize is ward-only; the manager check lives in Hub.initiateAuthorization.
        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.initiateAuthorization(poolId, fundAdmin, data);

        // No policy set for the pool, so authorize cannot classify the call.
        vm.expectRevert(IHubRegistry.PolicyNotInstalled.selector);
        registry.initiateAuthorization(poolId, fundAdmin, data);
    }

    function testConsumeAuthorizationOnlyCallableByPolicy(address caller, bytes calldata data, uint48 expiry) public {
        address fundAdmin = makeAddr("fundAdmin");
        IHubPolicy policy = IHubPolicy(makeAddr("policy"));

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);
        registry.setPolicy(poolId, policy);

        // Caller is address(this), not the pool's policy.
        vm.expectRevert(IHubRegistry.CallerNotPolicy.selector);
        registry.consumeAuthorization(poolId, caller, data, expiry);
    }

    function testUpdateCurrency(AssetId currency) public nonZero(address(uint160(currency.raw()))) {
        address fundAdmin = makeAddr("fundAdmin");

        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, fundAdmin, USD);

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateCurrency(poolId, currency);

        PoolId nonExistingPool = PoolId.wrap(0xDEAD);
        vm.expectRevert(IHubRegistry.NonExistingPool.selector);
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
        decimals = uint8(bound(decimals, 0, 18));
        assertFalse(registry.isRegistered(EUR));

        vm.prank(makeAddr("unauthorizedAddress"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.registerAsset(EUR, decimals);

        vm.expectEmit();
        emit IHubRegistry.NewAsset(EUR, decimals);
        registry.registerAsset(EUR, decimals);

        assertTrue(registry.isRegistered(EUR));
        assertEq(registry.decimals(EUR), decimals);
        assertEq(registry.decimals(uint256(AssetId.unwrap(EUR))), decimals);

        (bool registered, uint8 assetDecimals) = registry.asset(EUR);
        assertTrue(registered);
        assertEq(assetDecimals, decimals);
    }

    function testRegisterAssetNullId() public {
        vm.expectRevert(IHubRegistry.EmptyAssetId.selector);
        registry.registerAsset(AssetId.wrap(0), 6);
    }

    function testRegisterAssetTooManyDecimals(uint8 decimals) public {
        decimals = uint8(bound(decimals, 19, type(uint8).max));

        vm.expectRevert(IHubRegistry.TooManyDecimals.selector);
        registry.registerAsset(EUR, decimals);
    }

    function testAssetGetter() public {
        // Unregistered asset reads as (false, 0), not a revert.
        (bool registered, uint8 assetDecimals) = registry.asset(EUR);
        assertFalse(registered);
        assertEq(assetDecimals, 0);

        registry.registerAsset(EUR, 6);

        (registered, assetDecimals) = registry.asset(EUR);
        assertTrue(registered);
        assertEq(assetDecimals, 6);
    }

    function testRegisterAssetZeroDecimals() public {
        assertFalse(registry.isRegistered(EUR));

        registry.registerAsset(EUR, 0);

        // A 0-decimal asset is registered, not conflated with "not registered".
        assertTrue(registry.isRegistered(EUR));
        assertEq(registry.decimals(EUR), 0);
        assertEq(registry.decimals(uint256(AssetId.unwrap(EUR))), 0);

        // And usable as a pool currency, whose decimals(PoolId) getter returns 0.
        PoolId poolId = registry.poolId(CENTRIFUGE_ID, 1);
        registry.registerPool(poolId, makeAddr("fundAdmin"), EUR);
        assertEq(registry.decimals(poolId), 0);
    }

    function testRegisterAssetRevertsOnDuplicate() public {
        registry.registerAsset(EUR, 6);

        vm.expectRevert(IHubRegistry.AssetAlreadyRegistered.selector);
        registry.registerAsset(EUR, 6);

        // A different decimals value does not change the outcome: still reverts, no overwrite.
        vm.expectRevert(IHubRegistry.AssetAlreadyRegistered.selector);
        registry.registerAsset(EUR, 18);

        assertEq(registry.decimals(EUR), 6);
    }

    function testRegisterAssetZeroDecimalsRevertsOnDuplicate() public {
        registry.registerAsset(EUR, 0);

        // The registered flag, not the decimals value, gates re-registration.
        vm.expectRevert(IHubRegistry.AssetAlreadyRegistered.selector);
        registry.registerAsset(EUR, 0);
    }

    function testDecimalsRevertsOnUnregistered() public {
        AssetId unregistered = AssetId.wrap(978);

        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        registry.decimals(unregistered);

        vm.expectRevert(IHubRegistry.AssetNotFound.selector);
        registry.decimals(uint256(AssetId.unwrap(unregistered)));
    }

    function testUpdateCurrencyRevertsOnDecimalsMismatch() public {
        // Incumbent pool currency (USD, registered in setUp): 6 decimals.
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
