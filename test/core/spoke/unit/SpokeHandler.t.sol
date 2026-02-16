// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {ITransferHook} from "../../../../src/core/spoke/interfaces/ITransferHook.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {SpokeHandler, ISpokeHandler} from "../../../../src/core/spoke/SpokeHandler.sol";
import {ITokenFactory} from "../../../../src/core/spoke/factories/interfaces/ITokenFactory.sol";
import {IPoolEscrowFactory} from "../../../../src/core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import "forge-std/Test.sol";

contract IsContract {}

contract SpokeHandlerTest is Test {
    using CastLib for *;

    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable RECEIVER = makeAddr("RECEIVER");

    ISpokeRegistry spokeRegistry = ISpokeRegistry(address(new IsContract()));
    ITokenFactory tokenFactory = ITokenFactory(address(new IsContract()));
    IPoolEscrowFactory poolEscrowFactory = IPoolEscrowFactory(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));
    IPoolEscrow escrow = IPoolEscrow(address(new IsContract()));
    IRequestManager requestManager = IRequestManager(address(new IsContract()));

    address HOOK = makeAddr("hook");
    address HOOK2 = makeAddr("hook2");
    address NO_HOOK = address(0);

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(LOCAL_CENTRIFUGE_ID, 1);

    uint8 constant DECIMALS = 18;
    string constant NAME = "name";
    string constant SYMBOL = "symbol";
    bytes32 constant SALT = "salt";
    bytes constant PAYLOAD = "payload";

    D18 immutable PRICE = d18(42e18);
    uint128 constant AMOUNT = 200;
    uint64 immutable MAX_AGE = 10_000;
    uint64 immutable FUTURE = MAX_AGE + 1;

    SpokeHandler handler = new SpokeHandler(spokeRegistry, tokenFactory, poolEscrowFactory, AUTH);

    function setUp() public virtual {
        vm.warp(MAX_AGE);
        _mockBaseStuff();
    }

    function _mockBaseStuff() private {
        vm.mockCall(address(share), abi.encodeWithSelector(share.name.selector), abi.encode(NAME));
        vm.mockCall(address(share), abi.encodeWithSelector(share.symbol.selector), abi.encode(SYMBOL));
        vm.mockCall(address(share), abi.encodeWithSelector(share.hook.selector), abi.encode(HOOK));
    }

    function _mockShareToken() internal {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, POOL_A, SC_1),
            abi.encode(share)
        );
    }
}

contract SpokeHandlerTestFile is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.file("unknown", address(1));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeHandler.FileUnrecognizedParam.selector);
        handler.file("unknown", address(1));
    }

    function testFile() public {
        vm.startPrank(AUTH);
        vm.expectEmit();
        emit ISpokeHandler.File("spokeRegistry", address(23));
        handler.file("spokeRegistry", address(23));
        assertEq(address(handler.spokeRegistry()), address(23));

        handler.file("tokenFactory", address(42));
        assertEq(address(handler.tokenFactory()), address(42));

        handler.file("poolEscrowFactory", address(88));
        assertEq(address(handler.poolEscrowFactory()), address(88));
    }
}

contract SpokeHandlerTestAddPool is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.addPool(POOL_A);
    }

    function testAddPool() public {
        vm.mockCall(
            address(poolEscrowFactory),
            abi.encodeWithSelector(poolEscrowFactory.newEscrow.selector, POOL_A),
            abi.encode(escrow)
        );
        vm.mockCall(
            address(spokeRegistry), abi.encodeWithSelector(ISpokeRegistry.addPool.selector, POOL_A), abi.encode()
        );

        vm.prank(AUTH);
        handler.addPool(POOL_A);
    }
}

contract SpokeHandlerTestAddShareClass is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, NO_HOOK);
    }

    function testAddShareClass() public {
        vm.mockCall(
            address(tokenFactory),
            abi.encodeWithSelector(tokenFactory.newToken.selector, NAME, SYMBOL, DECIMALS, SALT),
            abi.encode(share)
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.addShareClass.selector, POOL_A, SC_1, share),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, NO_HOOK);
    }

    function testAddShareClassWithHook() public {
        vm.mockCall(
            address(tokenFactory),
            abi.encodeWithSelector(tokenFactory.newToken.selector, NAME, SYMBOL, DECIMALS, SALT),
            abi.encode(share)
        );
        vm.mockCall(
            address(share), abi.encodeWithSignature("file(bytes32,address)", bytes32("hook"), HOOK), abi.encode()
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.addShareClass.selector, POOL_A, SC_1, share),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, HOOK);
    }
}

contract SpokeHandlerTestSetRequestManager is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.setRequestManager(POOL_A, requestManager);
    }

    function testSetRequestManager() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.setRequestManager.selector, POOL_A, requestManager),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.setRequestManager(POOL_A, requestManager);
    }
}

contract SpokeHandlerTestUpdateShareMetadata is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.updateShareMetadata(POOL_A, SC_1, NAME, SYMBOL);
    }

    function testErrOldMetadata() public {
        _mockShareToken();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeHandler.OldMetadata.selector);
        handler.updateShareMetadata(POOL_A, SC_1, NAME, SYMBOL);
    }

    function testUpdateShareMetadata() public {
        _mockShareToken();

        string memory file = "file(bytes32,string)";
        vm.mockCall(address(share), abi.encodeWithSignature(file, bytes32("name"), "name2"), abi.encode());
        vm.mockCall(address(share), abi.encodeWithSignature(file, bytes32("symbol"), "symbol2"), abi.encode());

        vm.prank(AUTH);
        handler.updateShareMetadata(POOL_A, SC_1, "name2", "symbol2");
    }
}

contract SpokeHandlerTestUpdateShareHook is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.updateShareHook(POOL_A, SC_1, HOOK);
    }

    function testErrOldHook() public {
        _mockShareToken();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeHandler.OldHook.selector);
        handler.updateShareHook(POOL_A, SC_1, HOOK);
    }

    function testUpdateShareHook() public {
        _mockShareToken();

        vm.mockCall(
            address(share), abi.encodeWithSignature("file(bytes32,address)", bytes32("hook"), HOOK2), abi.encode()
        );

        vm.prank(AUTH);
        handler.updateShareHook(POOL_A, SC_1, HOOK2);
    }
}

contract SpokeHandlerTestUpdateRestriction is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.updateRestriction(POOL_A, SC_1, PAYLOAD);
    }

    function testErrInvalidHook() public {
        _mockShareToken();
        vm.mockCall(address(share), abi.encodeWithSelector(share.hook.selector), abi.encode(address(0)));

        vm.prank(AUTH);
        vm.expectRevert(ISpokeHandler.InvalidHook.selector);
        handler.updateRestriction(POOL_A, SC_1, PAYLOAD);
    }

    function testUpdateRestriction() public {
        _mockShareToken();

        vm.mockCall(
            address(HOOK),
            abi.encodeWithSelector(ITransferHook(HOOK).updateRestriction.selector, share, PAYLOAD),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.updateRestriction(POOL_A, SC_1, PAYLOAD);
    }
}

contract SpokeHandlerTestExecuteTransferShares is SpokeHandlerTest {
    using CastLib for *;

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.executeTransferShares(POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT);
    }

    function testExecuteTransferShares() public {
        _mockShareToken();

        vm.mockCall(address(share), abi.encodeWithSelector(share.mint.selector, address(handler), AMOUNT), abi.encode());
        vm.mockCall(address(share), abi.encodeWithSelector(share.transfer.selector, RECEIVER, AMOUNT), abi.encode(true));

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeHandler.ExecuteTransferShares(POOL_A, SC_1, RECEIVER, AMOUNT);
        handler.executeTransferShares(POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT);
    }
}

contract SpokeHandlerTestRequestCallback is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.requestCallback(POOL_A, SC_1, ASSET_ID, PAYLOAD);
    }

    function testErrInvalidRequestManager() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.requestManager.selector, POOL_A),
            abi.encode(address(0))
        );

        vm.prank(AUTH);
        vm.expectRevert(ISpokeHandler.InvalidRequestManager.selector);
        handler.requestCallback(POOL_A, SC_1, ASSET_ID, PAYLOAD);
    }

    function testRequestCallback() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.requestManager.selector, POOL_A),
            abi.encode(requestManager)
        );

        vm.mockCall(
            address(requestManager),
            abi.encodeWithSelector(requestManager.callback.selector, POOL_A, SC_1, ASSET_ID, PAYLOAD),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.requestCallback(POOL_A, SC_1, ASSET_ID, PAYLOAD);
    }
}

contract SpokeHandlerTestPriceDelegation is SpokeHandlerTest {
    function testUpdatePricePoolPerShare() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.updatePricePoolPerShare.selector, POOL_A, SC_1, PRICE, FUTURE),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);
    }

    function testUpdatePricePoolPerAsset() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(
                ISpokeRegistry.updatePricePoolPerAsset.selector, POOL_A, SC_1, ASSET_ID, PRICE, FUTURE
            ),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID, PRICE, FUTURE);
    }

    function testSetMaxSharePriceAge() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.setMaxSharePriceAge.selector, POOL_A, SC_1, MAX_AGE),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);
    }

    function testSetMaxAssetPriceAge() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.setMaxAssetPriceAge.selector, POOL_A, SC_1, ASSET_ID, MAX_AGE),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID, MAX_AGE);
    }
}
