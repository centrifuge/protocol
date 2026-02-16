// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {SpokeRegistry, ISpokeRegistry} from "../../../../src/core/spoke/SpokeRegistry.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract SpokeRegistryTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");

    IShareToken share = IShareToken(address(new IsContract()));
    IRequestManager requestManager = IRequestManager(address(new IsContract()));

    address erc20 = address(new IsContract());
    address erc6909 = address(new IsContract());
    uint256 constant TOKEN_1 = 23;

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    AssetId immutable ASSET_ID = newAssetId(LOCAL_CENTRIFUGE_ID, 1);

    D18 immutable PRICE = d18(42e18);
    uint64 immutable MAX_AGE = 10_000;
    uint64 immutable PRESENT = MAX_AGE;
    uint64 immutable FUTURE = MAX_AGE + 1;

    SpokeRegistry registry = new SpokeRegistry(AUTH);

    function setUp() public virtual {
        vm.warp(MAX_AGE);
    }

    function _addPool() internal {
        vm.prank(AUTH);
        registry.addPool(POOL_A);
    }

    function _addPoolAndShareClass() internal {
        _addPool();
        vm.prank(AUTH);
        registry.addShareClass(POOL_A, SC_1, share);
    }

    function _registerAsset() internal {
        vm.prank(AUTH);
        registry.registerAsset(ASSET_ID, erc6909, TOKEN_1);
    }
}

contract SpokeRegistryTestAddPool is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.addPool(POOL_A);
    }

    function testErrPoolAlreadyAdded() public {
        _addPool();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.PoolAlreadyAdded.selector);
        registry.addPool(POOL_A);
    }

    function testAddPool() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.AddPool(POOL_A);
        registry.addPool(POOL_A);

        assertEq(registry.pool(POOL_A), block.timestamp);
        assertEq(registry.isPoolActive(POOL_A), true);
    }
}

contract SpokeRegistryTestAddShareClass is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.addShareClass(POOL_A, SC_1, share);
    }

    function testErrInvalidPool() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.addShareClass(POOL_A, SC_1, share);
    }

    function testErrShareClassAlreadyRegistered() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.ShareClassAlreadyRegistered.selector);
        registry.addShareClass(POOL_A, SC_1, share);
    }

    function testAddShareClass() public {
        _addPool();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.AddShareClass(POOL_A, SC_1, share);
        registry.addShareClass(POOL_A, SC_1, share);

        assertEq(address(registry.shareToken(POOL_A, SC_1)), address(share));
    }
}

contract SpokeRegistryTestLinkToken is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.linkToken(POOL_A, SC_1, share);
    }

    function testLinkToken() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.AddShareClass(POOL_A, SC_1, share);
        registry.linkToken(POOL_A, SC_1, share);

        assertEq(address(registry.shareToken(POOL_A, SC_1)), address(share));

        (PoolId returnedPoolId, ShareClassId returnedScId) = registry.shareTokenDetails(address(share));
        assertEq(returnedPoolId.raw(), POOL_A.raw());
        assertEq(returnedScId.raw(), SC_1.raw());
    }
}

contract SpokeRegistryTestSetRequestManager is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setRequestManager(POOL_A, requestManager);
    }

    function testErrInvalidPool() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.setRequestManager(POOL_A, requestManager);
    }

    function testSetRequestManager() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.SetRequestManager(POOL_A, requestManager);
        registry.setRequestManager(POOL_A, requestManager);

        assertEq(address(registry.requestManager(POOL_A)), address(requestManager));
    }
}

contract SpokeRegistryTestRegisterAsset is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.registerAsset(ASSET_ID, erc6909, TOKEN_1);
    }

    function testRegisterAsset() public {
        _registerAsset();

        assertEq(registry.assetToId(erc6909, TOKEN_1).raw(), ASSET_ID.raw());

        (address asset, uint256 tokenId) = registry.idToAsset(ASSET_ID);
        assertEq(asset, erc6909);
        assertEq(tokenId, TOKEN_1);
    }
}

contract SpokeRegistryTestGenerateAssetId is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.generateAssetId(LOCAL_CENTRIFUGE_ID);
    }

    function testGenerateAssetId() public {
        vm.prank(AUTH);
        AssetId id1 = registry.generateAssetId(LOCAL_CENTRIFUGE_ID);
        assertEq(id1.raw(), newAssetId(LOCAL_CENTRIFUGE_ID, 1).raw());

        vm.prank(AUTH);
        AssetId id2 = registry.generateAssetId(LOCAL_CENTRIFUGE_ID);
        assertEq(id2.raw(), newAssetId(LOCAL_CENTRIFUGE_ID, 2).raw());
    }
}

contract SpokeRegistryTestUpdatePricePoolPerShare is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE, PRESENT);
    }

    function testErrShareTokenDoesNotExist() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE, PRESENT);
    }

    function testErrCannotSetOlderPrice() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.CannotSetOlderPrice.selector);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE, PRESENT);
    }

    function testUpdatePricePoolPerShare() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UpdateSharePrice(POOL_A, SC_1, PRICE, FUTURE);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        (uint64 computeAt, uint64 maxAge, uint64 validUntil) = registry.markersPricePoolPerShare(POOL_A, SC_1);
        assertEq(computeAt, FUTURE);
        assertEq(maxAge, type(uint64).max);
        assertEq(validUntil, type(uint64).max);
    }

    function testMaxAgeNotOverwrittenAfterUpdatingPrice() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        registry.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);

        vm.prank(AUTH);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        (, uint64 maxAge,) = registry.markersPricePoolPerShare(POOL_A, SC_1);
        assertEq(maxAge, MAX_AGE);
    }
}

contract SpokeRegistryTestUpdatePricePoolPerAsset is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, PRESENT);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);
    }

    function testErrCannotSetOlderPrice() public {
        _registerAsset();

        vm.prank(AUTH);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.CannotSetOlderPrice.selector);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, PRESENT);
    }

    function testUpdatePricePoolPerAsset() public {
        _registerAsset();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UpdateAssetPrice(POOL_A, SC_1, erc6909, TOKEN_1, PRICE, FUTURE);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        (uint64 computeAt, uint64 maxAge, uint64 validUntil) = registry.markersPricePoolPerAsset(POOL_A, SC_1, ASSET_ID);
        assertEq(computeAt, FUTURE);
        assertEq(maxAge, type(uint64).max);
        assertEq(validUntil, type(uint64).max);
    }
}

contract SpokeRegistryTestSetMaxSharePriceAge is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);
    }

    function testErrShareTokenDoesNotExist() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        registry.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);
    }

    function testSetMaxSharePriceAge() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UpdateMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);
        registry.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);

        (, uint64 maxAge, uint64 validUntil) = registry.markersPricePoolPerShare(POOL_A, SC_1);
        assertEq(maxAge, MAX_AGE);
        assertEq(validUntil, MAX_AGE);
    }
}

contract SpokeRegistryTestSetMaxAssetPriceAge is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID, MAX_AGE);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        registry.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID, MAX_AGE);
    }

    function testSetMaxAssetPriceAge() public {
        _registerAsset();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UpdateMaxAssetPriceAge(POOL_A, SC_1, erc6909, TOKEN_1, MAX_AGE);
        registry.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID, MAX_AGE);

        (, uint64 maxAge, uint64 validUntil) = registry.markersPricePoolPerAsset(POOL_A, SC_1, ASSET_ID);
        assertEq(maxAge, MAX_AGE);
        assertEq(validUntil, MAX_AGE);
    }
}

contract SpokeRegistryTestPricePoolPerShare is SpokeRegistryTest {
    function testErrShareTokenDoesNotExist() public {
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        registry.pricePoolPerShare(POOL_A, SC_1, false);
    }

    function testErrInvalidPrice() public {
        _addPoolAndShareClass();

        vm.expectRevert(ISpokeRegistry.InvalidPrice.selector);
        registry.pricePoolPerShare(POOL_A, SC_1, true);
    }

    function testPricePoolPerShareWithoutValidity() public {
        _addPoolAndShareClass();

        D18 price = registry.pricePoolPerShare(POOL_A, SC_1, false);
        assertEq(price.raw(), 0);
    }

    function testPricePoolPerShareWithValidity() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        D18 price = registry.pricePoolPerShare(POOL_A, SC_1, true);
        assertEq(price.raw(), PRICE.raw());
    }
}

contract SpokeRegistryTestPricePoolPerAsset is SpokeRegistryTest {
    function testErrInvalidPrice() public {
        vm.expectRevert(ISpokeRegistry.InvalidPrice.selector);
        registry.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID, true);
    }

    function testPricePoolPerAssetWithoutValidity() public {
        D18 price = registry.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID, false);
        assertEq(price.raw(), 0);
    }

    function testPricePoolPerAssetWithValidity() public {
        _registerAsset();

        vm.prank(AUTH);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        D18 price = registry.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID, true);
        assertEq(price.raw(), PRICE.raw());
    }
}

contract SpokeRegistryTestPricesPoolPer is SpokeRegistryTest {
    function testErrShareTokenDoesNotExist() public {
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        registry.pricesPoolPer(POOL_A, SC_1, ASSET_ID, false);
    }

    function testErrInvalidPrice() public {
        _registerAsset();
        _addPoolAndShareClass();

        vm.expectRevert(ISpokeRegistry.InvalidPrice.selector);
        registry.pricesPoolPer(POOL_A, SC_1, ASSET_ID, true);
    }

    function testPricesPoolPerWithValidity() public {
        _registerAsset();
        _addPoolAndShareClass();

        vm.prank(AUTH);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        vm.prank(AUTH);
        registry.updatePricePoolPerShare(POOL_A, SC_1, PRICE + d18(1), FUTURE);

        (D18 assetPrice, D18 sharePrice) = registry.pricesPoolPer(POOL_A, SC_1, ASSET_ID, true);
        assertEq(assetPrice.raw(), PRICE.raw());
        assertEq(sharePrice.raw(), (PRICE + d18(1)).raw());
    }
}

contract SpokeRegistryTestShareTokenDetails is SpokeRegistryTest {
    function testErrShareTokenDoesNotExist() public {
        address nonExistentToken = makeAddr("nonExistentToken");

        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        registry.shareTokenDetails(nonExistentToken);
    }
}
