// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IPolicy} from "../../../../src/core/utils/interfaces/IPolicy.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {SpokeRegistry, ISpokeRegistry} from "../../../../src/core/spoke/SpokeRegistry.sol";
import {ISpokeRequestManager} from "../../../../src/core/spoke/interfaces/ISpokeRequestManager.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract SpokeRegistryTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");

    address share = address(new IsContract());
    IRegistrar registrar = IRegistrar(address(new IsContract()));
    ISpokeRequestManager requestManager = ISpokeRequestManager(address(new IsContract()));

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

    function testErrNullPoolId() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.addPool(PoolId.wrap(0));
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
        (, IRegistrar registrar_) = registry.shareTokenAndRegistrar(POOL_A, SC_1);
        assertEq(address(registrar_), address(registrar));

        (PoolId poolId, ShareClassId scId) = registry.tokenDetails(share);
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

    function testErrEmptyRegistrar() public {
        _addPool();

        // The registrar slot is the share-class existence sentinel, so it must be non-zero
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.EmptyRegistrar.selector);
        registry.addShareClass(POOL_A, SC_1, share, IRegistrar(address(0)));
    }
}

contract SpokeRegistryTestLinkToken is SpokeRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.linkToken(POOL_A, SC_1, share, registrar);
    }

    function testErrInvalidPool() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.linkToken(POOL_A, SC_1, share, registrar);
    }

    function testErrNotAContract() public {
        _addPool();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.NotAContract.selector);
        registry.linkToken(POOL_A, SC_1, makeAddr("noCode"), registrar);
    }

    function testLinkToken() public {
        _addPool();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.AddShareClass(POOL_A, SC_1, share, registrar);
        registry.linkToken(POOL_A, SC_1, share, registrar);

        assertEq(address(registry.shareToken(POOL_A, SC_1)), share);
        (, IRegistrar registrar_) = registry.shareTokenAndRegistrar(POOL_A, SC_1);
        assertEq(address(registrar_), address(registrar));

        (PoolId poolId, ShareClassId scId) = registry.tokenDetails(share);
        assertEq(poolId.raw(), POOL_A.raw());
        assertEq(scId.raw(), SC_1.raw());
    }

    function testLinkTokenSwapRetiresOldToken() public {
        _addPoolAndShareClass();

        // Swap the share class's token: the new token resolves, the outgoing one is retired.
        address newShare = address(new IsContract());
        vm.prank(AUTH);
        registry.linkToken(POOL_A, SC_1, newShare, registrar);

        assertEq(address(registry.shareToken(POOL_A, SC_1)), newShare);
        (PoolId poolId, ShareClassId scId) = registry.tokenDetails(newShare);
        assertEq(poolId.raw(), POOL_A.raw());
        assertEq(scId.raw(), SC_1.raw());

        // The retired token no longer resolves to any share class.
        (PoolId retiredPoolId,) = registry.tokenDetails(share);
        assertEq(retiredPoolId.raw(), 0);

        // The retired token's address is free again for another share class.
        vm.prank(AUTH);
        registry.linkToken(POOL_A, ShareClassId.wrap(bytes16("sc2")), share, registrar);
    }

    function testLinkTokenSwapRegistrarKeepsToken() public {
        _addPoolAndShareClass();

        // Swap the registrar while keeping the same token (e.g. a registrar bugfix redeploy). This used
        // to revert with TokenAlreadyRegistered because the token's own reverse lookup tripped the check.
        IRegistrar newRegistrar = IRegistrar(address(new IsContract()));
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.AddShareClass(POOL_A, SC_1, share, newRegistrar);
        registry.linkToken(POOL_A, SC_1, share, newRegistrar);

        (, IRegistrar registrar_) = registry.shareTokenAndRegistrar(POOL_A, SC_1);
        assertEq(address(registrar_), address(newRegistrar));

        // The token still resolves to the same share class.
        (PoolId poolId, ShareClassId scId) = registry.tokenDetails(share);
        assertEq(poolId.raw(), POOL_A.raw());
        assertEq(scId.raw(), SC_1.raw());
    }

    /// @dev The reorder retires the outgoing token's reverse lookup before the uniqueness check, so the
    ///      cross-link case has to stay closed: linking a token already bound to another share class must
    ///      revert, and the revert must roll the retired lookup back rather than orphaning the outgoing token.
    function testLinkTokenCrossLinkRevertsAndRollsBackOutgoingLookup() public {
        _addPoolAndShareClass();

        // A second share class in the same pool, with its own token.
        ShareClassId scId2 = ShareClassId.wrap(bytes16("sc2"));
        address share2 = address(new IsContract());
        vm.prank(AUTH);
        registry.addShareClass(POOL_A, scId2, share2, registrar);

        // Point SC_1 at SC_2's token: `share2` is already registered, so this must revert.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.TokenAlreadyRegistered.selector);
        registry.linkToken(POOL_A, SC_1, share2, registrar);

        // SC_1 keeps its own token, and that token's reverse lookup survived the rollback.
        (IERC20 token1,) = registry.shareTokenAndRegistrar(POOL_A, SC_1);
        assertEq(address(token1), share);
        (PoolId poolId1, ShareClassId scId1) = registry.tokenDetails(share);
        assertEq(poolId1.raw(), POOL_A.raw());
        assertEq(scId1.raw(), SC_1.raw());

        // SC_2 is untouched.
        (PoolId poolId2, ShareClassId scId2Lookup) = registry.tokenDetails(share2);
        assertEq(poolId2.raw(), POOL_A.raw());
        assertEq(scId2Lookup.raw(), scId2.raw());
    }
}

contract SpokeRegistryTestTokenDetails is SpokeRegistryTest {
    function testUnregisteredReturnsZero() public view {
        (PoolId poolId,) = registry.tokenDetails(share);
        assertEq(poolId.raw(), 0);
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

    function testErrInvalidPoolBridger() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.updateBridger(POOL_A, ANY, true);
    }

    function testErrInvalidPoolManager() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.updateManager(POOL_A, ANY, true);
    }

    function testUpdateBridger() public {
        _addPool();

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

    function testErrZeroAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        registry.createAssetId(LOCAL_CENTRIFUGE_ID, address(0), 0);
    }

    function testErrInvalidCentrifugeId() public {
        // A zero centrifugeId would produce raw ids colliding with the ISO-4217 currency encoding.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidCentrifugeId.selector);
        registry.createAssetId(0, erc20, 0);
    }

    function testErrAssetAlreadyRegistered() public {
        _createAssetId();

        // Re-registering the same (asset, tokenId) would orphan the previously issued id.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.AssetAlreadyRegistered.selector);
        registry.createAssetId(LOCAL_CENTRIFUGE_ID, erc6909, TOKEN_1);
    }

    function testIdToAssetRevertOnNull() public {
        AssetId unknown = newAssetId(LOCAL_CENTRIFUGE_ID, 99);

        // The bare getter (and revertOnNull == false) is non-reverting and returns zero values on a miss.
        (address asset, uint256 tokenId) = registry.idToAsset(unknown);
        assertEq(asset, address(0));
        assertEq(tokenId, 0);
        (asset,) = registry.idToAsset(unknown, false);
        assertEq(asset, address(0));

        // revertOnNull == true fails closed, which is how resolve-callers reject a missing asset.
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        registry.idToAsset(unknown, true);
    }

    function testAssetToIdRevertOnNull() public {
        // The bare getter (and revertOnNull == false) returns null on a miss; registerAsset relies on this to
        // detect a not-yet-registered asset.
        assertTrue(registry.assetToId(erc20, 0).isNull());
        assertTrue(registry.assetToId(erc20, 0, false).isNull());

        // revertOnNull == true fails closed.
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        registry.assetToId(erc20, 0, true);
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

    function testErrShareTokenDoesNotExist() public {
        _createAssetId();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);
    }

    function testErrUnknownAsset() public {
        _addPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);
    }

    function testErrCannotSetOlderPrice() public {
        _addPoolAndShareClass();
        _createAssetId();

        vm.prank(AUTH);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.CannotSetOlderPrice.selector);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, PRESENT);
    }

    function testUpdatePricePoolPerAsset() public {
        _addPoolAndShareClass();
        _createAssetId();

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UpdateAssetPrice(POOL_A, SC_1, erc6909, TOKEN_1, PRICE, FUTURE);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        assertEq(registry.pricePoolPerAssetComputedAt(POOL_A, SC_1, ASSET_ID), FUTURE);
    }
}

contract SpokeRegistryTestPricePoolPerShare is SpokeRegistryTest {
    function testUnregisteredWithoutValidityReturnsZero() public view {
        D18 price = registry.pricePoolPerShare(POOL_A, SC_1, false);
        assertEq(price.raw(), 0);
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
        _addPoolAndShareClass();
        _createAssetId();

        vm.prank(AUTH);
        registry.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);

        D18 price = registry.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID, true);
        assertEq(price.raw(), PRICE.raw());
    }
}

contract SpokeRegistryTestAuthorization is SpokeRegistryTest {
    IPolicy policy = IPolicy(makeAddr("policy"));
    bytes data = hex"1234";

    function _installPolicy() internal {
        _addPool();
        vm.prank(AUTH);
        registry.setPolicy(POOL_A, policy);
    }

    function testSetPolicyErrNotAuthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.setPolicy(POOL_A, policy);
    }

    function testSetPolicyErrInvalidPool() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidPool.selector);
        registry.setPolicy(POOL_A, policy);
    }

    function testSetPolicy() public {
        _addPool();

        vm.expectEmit();
        emit ISpokeRegistry.SetPolicy(POOL_A, policy);
        vm.prank(AUTH);
        registry.setPolicy(POOL_A, policy);

        assertEq(address(registry.policy(POOL_A)), address(policy));
        assertEq(registry.policyNonce(POOL_A), 1);
    }

    function testAuthorizeErrNotAuthorized() public {
        // Only the message layer (a ward) may record a Hub-authorized call; there is no local scheduling.
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.authorize(POOL_A, data);
    }

    function testAuthorizeErrPolicyNotInstalled() public {
        // Recording an authorization for a pool with no policy would be unconsumable, so it reverts.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.PolicyNotInstalled.selector);
        registry.authorize(POOL_A, data);
    }

    function testAuthorizeAndConsume() public {
        _installPolicy();
        bytes32 id = registry.authId(POOL_A, data);

        // Several authorizations of the same call can be outstanding at once (a counter, not a flag).
        vm.prank(AUTH);
        registry.authorize(POOL_A, data);
        assertEq(registry.authorizations(id), 1);

        vm.prank(AUTH);
        registry.authorize(POOL_A, data);
        assertEq(registry.authorizations(id), 2);

        // The pool's policy consumes one at a time.
        vm.prank(address(policy));
        registry.consumeAuthorization(POOL_A, address(this), data);
        assertEq(registry.authorizations(id), 1);

        vm.prank(address(policy));
        registry.consumeAuthorization(POOL_A, address(this), data);
        assertEq(registry.authorizations(id), 0);

        // Nothing left to consume.
        vm.prank(address(policy));
        vm.expectRevert(ISpokeRegistry.NoOutstandingAuthorization.selector);
        registry.consumeAuthorization(POOL_A, address(this), data);
    }

    function testConsumeAuthorizationOnlyCallableByPolicy() public {
        _installPolicy();

        // Caller is address(this), not the pool's policy.
        vm.expectRevert(ISpokeRegistry.CallerNotPolicy.selector);
        registry.consumeAuthorization(POOL_A, address(this), data);
    }

    function testUnauthorizeErrNotAuthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        registry.unauthorize(POOL_A, data);
    }

    function testUnauthorize() public {
        _installPolicy();
        bytes32 id = registry.authId(POOL_A, data);

        vm.startPrank(AUTH);
        registry.authorize(POOL_A, data);
        registry.authorize(POOL_A, data);
        assertEq(registry.authorizations(id), 2);

        // Each revoke decrements one outstanding authorization.
        registry.unauthorize(POOL_A, data);
        assertEq(registry.authorizations(id), 1);
        registry.unauthorize(POOL_A, data);
        assertEq(registry.authorizations(id), 0);

        // Nothing left to revoke.
        vm.expectRevert(ISpokeRegistry.NoOutstandingAuthorization.selector);
        registry.unauthorize(POOL_A, data);
        vm.stopPrank();
    }

    function testPolicyReinstallChangesAuthId() public {
        _installPolicy();
        bytes32 id = registry.authId(POOL_A, data);

        // Re-installing the same policy address bumps the nonce, re-namespacing every id.
        vm.prank(AUTH);
        registry.setPolicy(POOL_A, policy);
        assertEq(registry.policyNonce(POOL_A), 2);
        assertNotEq(registry.authId(POOL_A, data), id);
    }

    function testPolicySwapBackDoesNotResurrectAuthorization() public {
        _installPolicy();

        vm.prank(AUTH);
        registry.authorize(POOL_A, data);

        // Swap the policy away and back: the outstanding authorization must not be resurrected.
        vm.startPrank(AUTH);
        registry.setPolicy(POOL_A, IPolicy(makeAddr("otherPolicy")));
        registry.setPolicy(POOL_A, policy);
        vm.stopPrank();

        vm.prank(address(policy));
        vm.expectRevert(ISpokeRegistry.NoOutstandingAuthorization.selector);
        registry.consumeAuthorization(POOL_A, address(this), data);
    }
}
