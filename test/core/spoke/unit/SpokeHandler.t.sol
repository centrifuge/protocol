// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {IERC20} from "../../../../src/misc/interfaces/IERC20.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IPolicy} from "../../../../src/core/utils/interfaces/IPolicy.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {SpokeHandler, ISpokeHandler} from "../../../../src/core/spoke/SpokeHandler.sol";
import {ISpokeRequestManager} from "../../../../src/core/spoke/interfaces/ISpokeRequestManager.sol";
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
    IRegistrar registrar = IRegistrar(address(new IsContract()));
    IPoolEscrowFactory poolEscrowFactory = IPoolEscrowFactory(address(new IsContract()));
    address share = address(new IsContract());
    IPoolEscrow escrow = IPoolEscrow(address(new IsContract()));
    ISpokeRequestManager requestManager = ISpokeRequestManager(address(new IsContract()));

    address HOOK = makeAddr("hook");
    address HOOK2 = makeAddr("hook2");
    address NO_HOOK = address(0);

    uint64 constant POOL_A_RAW = 1;
    PoolId constant POOL_A = PoolId.wrap(POOL_A_RAW);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(LOCAL_CENTRIFUGE_ID, 1);

    uint8 constant DECIMALS = 18;
    string constant NAME = "name";
    string constant SYMBOL = "symbol";
    // A share class salt carries its pool id in the leading 8 bytes
    bytes32 constant SALT = bytes32(uint256(POOL_A_RAW) << 192 | uint256(uint64(bytes8("salt"))));
    bytes constant PAYLOAD = "payload";

    D18 immutable PRICE = d18(42e18);
    uint128 constant AMOUNT = 200;
    uint64 immutable MAX_AGE = 10_000;
    uint64 immutable FUTURE = MAX_AGE + 1;

    SpokeHandler handler = new SpokeHandler(spokeRegistry, poolEscrowFactory, AUTH);

    function setUp() public virtual {
        vm.warp(MAX_AGE);
    }

    function _mockShareToken() internal {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(share, registrar)
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
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, registrar, PAYLOAD);
    }

    function testErrInvalidRegistrar() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeHandler.InvalidRegistrar.selector);
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, IRegistrar(address(0)), PAYLOAD);
    }

    function testErrInvalidSalt() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeHandler.InvalidSalt.selector);
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, "salt", registrar, PAYLOAD);
    }

    function _mockNewToken() internal {
        vm.mockCall(
            address(registrar),
            abi.encodeCall(IRegistrar.newToken, (NAME, SYMBOL, DECIMALS, SALT, PAYLOAD)),
            abi.encode(share)
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.addShareClass.selector, POOL_A, SC_1, share, registrar),
            abi.encode()
        );
    }

    function testAddShareClass() public {
        _mockNewToken();

        vm.prank(AUTH);
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, registrar, PAYLOAD);
    }

    function testAddShareClassZeroDecimals() public {
        vm.mockCall(
            address(registrar),
            abi.encodeCall(IRegistrar.newToken, (NAME, SYMBOL, uint8(0), SALT, PAYLOAD)),
            abi.encode(share)
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.addShareClass.selector, POOL_A, SC_1, share, registrar),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.addShareClass(POOL_A, SC_1, NAME, SYMBOL, 0, SALT, registrar, PAYLOAD);
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

    function testUpdateBridger() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.updateBridger.selector, POOL_A, ANY, true),
            abi.encode()
        );

        vm.prank(AUTH);
        handler.updateBridger(POOL_A, ANY, true);
    }
}

contract SpokeHandlerTestSetPolicy is SpokeHandlerTest {
    IPolicy immutable POLICY = IPolicy(makeAddr("Policy"));

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.setPolicy(POOL_A, POLICY);
    }

    function testSetPolicy() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.setPolicy.selector, POOL_A, POLICY),
            abi.encode()
        );

        vm.expectCall(address(spokeRegistry), abi.encodeWithSelector(ISpokeRegistry.setPolicy.selector, POOL_A, POLICY));
        vm.prank(AUTH);
        handler.setPolicy(POOL_A, POLICY);
    }

    function testAuthorizeErrNotAuthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.authorize(POOL_A, hex"1234");
    }

    function testAuthorize() public {
        bytes memory data = hex"1234";
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.authorize.selector, POOL_A, data),
            abi.encode()
        );

        vm.expectCall(address(spokeRegistry), abi.encodeWithSelector(ISpokeRegistry.authorize.selector, POOL_A, data));
        vm.prank(AUTH);
        handler.authorize(POOL_A, data);
    }

    function testUnauthorizeErrNotAuthorized() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.unauthorize(POOL_A, hex"1234");
    }

    function testUnauthorize() public {
        bytes memory data = hex"1234";
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.unauthorize.selector, POOL_A, data),
            abi.encode()
        );

        vm.expectCall(address(spokeRegistry), abi.encodeWithSelector(ISpokeRegistry.unauthorize.selector, POOL_A, data));
        vm.prank(AUTH);
        handler.unauthorize(POOL_A, data);
    }
}

contract SpokeHandlerTestUpdateShareMetadata is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.updateShareMetadata(POOL_A, SC_1, NAME, SYMBOL);
    }

    function testUpdateShareMetadata() public {
        _mockShareToken();

        bytes memory call = abi.encodeWithSelector(IRegistrar.updateMetadata.selector, share, "name2", "symbol2");
        vm.mockCall(address(registrar), call, abi.encode());
        vm.expectCall(address(registrar), call);

        vm.prank(AUTH);
        handler.updateShareMetadata(POOL_A, SC_1, "name2", "symbol2");
    }
}

contract SpokeHandlerTestUpdateRestriction is SpokeHandlerTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        handler.updateRestriction(POOL_A, SC_1, PAYLOAD);
    }

    function testUpdateRestriction() public {
        _mockShareToken();

        bytes memory call = abi.encodeWithSelector(IRegistrar.updateRestriction.selector, share, PAYLOAD);
        vm.mockCall(address(registrar), call, abi.encode());
        vm.expectCall(address(registrar), call);

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

        vm.mockCall(
            address(registrar),
            abi.encodeWithSelector(IRegistrar.mint.selector, share, address(handler), AMOUNT),
            abi.encode()
        );
        vm.mockCall(share, abi.encodeWithSelector(IERC20.transfer.selector, RECEIVER, AMOUNT), abi.encode(true));

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
}
