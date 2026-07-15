// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {SpokeRegistry, ISpokeRegistry} from "../../../../src/core/spoke/SpokeRegistry.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract SpokeRegistryTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");

    address share = address(new IsContract());
    IRegistrar registrar = IRegistrar(address(new IsContract()));
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
        registry.addShareClass(POOL_A, SC_1, share, registrar);
    }

    function _createAssetId() internal {
        vm.prank(AUTH);
        registry.createAssetId(LOCAL_CENTRIFUGE_ID, erc6909, TOKEN_1);
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
        registry.addShareClass(POOL_A, SC_1, share, registrar);
    }

    function testErrInvalidPool() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.addShareClass(POOL_A, SC_1, share, registrar);
    }

    function testErrShareClassAlreadyRegistered() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.ShareClassAlreadyRegistered.selector);
        registry.addShareClass(POOL_A, SC_1, share, registrar);
    }

    function testAddShareClass() public {
        _addPool();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.AddShareClass(POOL_A, SC_1, share, registrar);
        registry.addShareClass(POOL_A, SC_1, share, registrar);

        assertEq(address(registry.shareToken(POOL_A, SC_1)), share);
        assertEq(address(registry.registrar(POOL_A, SC_1)), address(registrar));

        (PoolId poolId, ShareClassId scId) = registry.shareTokenDetails(share);
        assertEq(poolId.raw(), POOL_A.raw());
        assertEq(scId.raw(), SC_1.raw());
    }

    function testErrTokenAlreadyRegistered() public {
        _addPoolAndShareClass();

        // The same token address cannot back a second share class
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.TokenAlreadyRegistered.selector);
        registry.addShareClass(POOL_A, ShareClassId.wrap(bytes16("sc2")), share, registrar);
    }

    function testErrNotAContract() public {
        _addPool();

        // An address with no code (e.g. a not-yet-deployed token) cannot be registered
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.NotAContract.selector);
        registry.addShareClass(POOL_A, SC_1, makeAddr("noCode"), registrar);
    }
}

contract SpokeRegistryTestLinkToken is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.linkToken(POOL_A, SC_1, share, registrar);
    }

    function testErrNotAContract() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.NotAContract.selector);
        registry.linkToken(POOL_A, SC_1, makeAddr("noCode"), registrar);
    }

    function testLinkToken() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.AddShareClass(POOL_A, SC_1, share, registrar);
        registry.linkToken(POOL_A, SC_1, share, registrar);

        assertEq(address(registry.shareToken(POOL_A, SC_1)), share);
        assertEq(address(registry.registrar(POOL_A, SC_1)), address(registrar));

        (PoolId poolId, ShareClassId scId) = registry.shareTokenDetails(share);
        assertEq(poolId.raw(), POOL_A.raw());
        assertEq(scId.raw(), SC_1.raw());
    }
}

contract SpokeRegistryTestShareTokenDetails is SpokeRegistryTest {
    function testErrShareTokenDoesNotExist() public {
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        registry.shareTokenDetails(share);
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

contract SpokeRegistryTestUpdateBridger is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.updateBridger(POOL_A, ANY, true);
    }

    function testUpdateBridger() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UpdateBridger(POOL_A, ANY, true);
        registry.updateBridger(POOL_A, ANY, true);
        assertEq(registry.bridger(POOL_A, ANY), true);

        vm.prank(AUTH);
        registry.updateBridger(POOL_A, ANY, false);
        assertEq(registry.bridger(POOL_A, ANY), false);
    }
}

contract SpokeRegistryTestCreateAssetId is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.createAssetId(LOCAL_CENTRIFUGE_ID, erc6909, TOKEN_1);
    }

    function testCreateAssetId() public {
        vm.prank(AUTH);
        AssetId id1 = registry.createAssetId(LOCAL_CENTRIFUGE_ID, erc6909, TOKEN_1);
        assertEq(id1.raw(), newAssetId(LOCAL_CENTRIFUGE_ID, 1).raw());
        assertEq(registry.assetToId(erc6909, TOKEN_1).raw(), id1.raw());

        (address asset, uint256 tokenId) = registry.idToAsset(id1);
        assertEq(asset, erc6909);
        assertEq(tokenId, TOKEN_1);

        vm.prank(AUTH);
        AssetId id2 = registry.createAssetId(LOCAL_CENTRIFUGE_ID, erc20, 0);
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

        assertEq(registry.pricePoolPerShareComputedAt(POOL_A, SC_1), FUTURE);
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
        _createAssetId();

        vm.prank(AUTH);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.CannotSetOlderPrice.selector);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, PRESENT);
    }

    function testUpdatePricePoolPerAsset() public {
        _createAssetId();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UpdateAssetPrice(POOL_A, SC_1, erc6909, TOKEN_1, PRICE, FUTURE);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        assertEq(registry.pricePoolPerAssetComputedAt(POOL_A, SC_1, ASSET_ID), FUTURE);
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

    function testPricePoolPerAssetWithoutValidity() public view {
        D18 price = registry.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID, false);
        assert(price.raw() == 0);
    }

    function testPricePoolPerAssetWithValidity() public {
        _createAssetId();

        vm.prank(AUTH);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        D18 price = registry.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID, true);
        assertEq(price.raw(), PRICE.raw());
    }
}
