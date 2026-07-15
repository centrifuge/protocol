// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {IERC6909MetadataExt} from "../../../../src/misc/interfaces/IERC6909.sol";
import {IERC20, IERC20Metadata} from "../../../../src/misc/interfaces/IERC20.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {Spoke, ISpoke} from "../../../../src/core/spoke/Spoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {ISpokeMessageSender} from "../../../../src/core/messaging/interfaces/IGatewaySenders.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../../../src/token/interfaces/IShareToken.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract SpokeTest is Test {
    using CastLib for *;

    uint16 constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable RECEIVER = makeAddr("RECEIVER");
    address immutable REFUND = makeAddr("REFUND");

    ISpokeRegistry spokeRegistry = ISpokeRegistry(address(new IsContract()));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));
    IRegistrar registrar = IRegistrar(address(new IsContract()));
    IRequestManager requestManager = IRequestManager(address(new IsContract()));

    address erc20 = address(new IsContract());
    address erc6909 = address(new IsContract());
    uint256 constant TOKEN_1 = 23;

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));

    AssetId immutable ASSET_ID_20 = newAssetId(LOCAL_CENTRIFUGE_ID, 1);
    AssetId immutable ASSET_ID_6909_1 = newAssetId(LOCAL_CENTRIFUGE_ID, 1);

    uint8 constant DECIMALS = 18;
    string constant NAME = "name";
    string constant SYMBOL = "symbol";
    bytes constant PAYLOAD = "payload";

    D18 immutable PRICE = d18(42e18);
    uint128 constant AMOUNT = 200;
    uint64 immutable MAX_AGE = 10_000;
    uint64 immutable PRESENT = MAX_AGE;
    uint64 immutable FUTURE = MAX_AGE + 1;

    uint256 constant COST = 123;
    uint128 constant EXTRA = 456;

    Spoke spoke = new Spoke(AUTH);

    function setUp() public virtual {
        vm.deal(ANY, 1 ether);
        vm.deal(AUTH, 1 ether);
        vm.deal(address(requestManager), 1 ether);

        vm.startPrank(AUTH);
        spoke.file("spokeRegistry", address(spokeRegistry));
        spoke.file("sender", address(sender));
        vm.stopPrank();

        vm.warp(MAX_AGE);

        _mockBaseStuff();
    }

    function _mockBaseStuff() private {
        vm.mockCall(
            address(sender), abi.encodeWithSelector(sender.localCentrifugeId.selector), abi.encode(LOCAL_CENTRIFUGE_ID)
        );
    }

    function _mockShareToken() internal {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(share, registrar)
        );

        vm.mockCall(address(share), abi.encodeWithSelector(share.hook.selector), abi.encode(address(0)));
    }

    function _mockERC20(uint8 decimals) internal {
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(decimals));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode(NAME));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode(SYMBOL));
    }

    function _mockERC6909(uint8 decimals, uint256 token) internal {
        vm.mockCall(
            address(erc6909), abi.encodeWithSelector(IERC6909MetadataExt.decimals.selector, token), abi.encode(decimals)
        );
        vm.mockCall(
            address(erc6909), abi.encodeWithSelector(IERC6909MetadataExt.name.selector, token), abi.encode(NAME)
        );
        vm.mockCall(
            address(erc6909), abi.encodeWithSelector(IERC6909MetadataExt.symbol.selector, token), abi.encode(SYMBOL)
        );
    }

    function _mockSendRegisterAsset(AssetId assetId) internal {
        _mockSendRegisterAsset(assetId, DECIMALS);
    }

    function _mockSendRegisterAsset(AssetId assetId, uint8 decimals) internal {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(sender.sendRegisterAsset.selector, REMOTE_CENTRIFUGE_ID, assetId, decimals),
            abi.encode()
        );
    }

    function _mockNewAssetRegistration(address asset, uint256 tokenId, AssetId assetId) internal {
        // Mock assetToIdOrNull to return null (asset not yet registered)
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.assetToIdOrNull.selector, asset, tokenId),
            abi.encode(AssetId.wrap(0))
        );
        // Mock createAssetId
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.createAssetId.selector, LOCAL_CENTRIFUGE_ID, asset, tokenId),
            abi.encode(assetId)
        );
    }

    function _mockExistingAssetRegistration(address asset, uint256 tokenId, AssetId assetId) internal {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.assetToIdOrNull.selector, asset, tokenId),
            abi.encode(assetId)
        );
    }
}

contract SpokeTestFile is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.file("unknown", address(1));
    }

    function testErrFileUnrecognizedParam() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.FileUnrecognizedParam.selector);
        spoke.file("unknown", address(1));
    }

    function testSpokeFile() public {
        vm.startPrank(AUTH);
        vm.expectEmit();
        emit ISpoke.File("spokeRegistry", address(23));
        spoke.file("spokeRegistry", address(23));
        assertEq(address(spoke.spokeRegistry()), address(23));

        spoke.file("sender", address(42));
        assertEq(address(spoke.sender()), address(42));
    }
}

contract SpokeTestCrosschainTransferShares is SpokeTest {
    using CastLib for *;

    function setUp() public override {
        super.setUp();
        // Default: caller is an authorized bridger; individual tests can override.
        vm.mockCall(address(spokeRegistry), abi.encodeWithSelector(ISpokeRegistry.bridger.selector), abi.encode(true));
    }

    function testErrNotBridger() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.bridger.selector, POOL_A, ANY),
            abi.encode(false)
        );

        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotBridger.selector);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 0, REFUND
        );
    }

    function _mockCrossTransferShare(address sender_, bool value) public {
        vm.mockCall(
            address(registrar),
            abi.encodeWithSelector(
                IRegistrar.canTransferCrosschain.selector, address(share), sender_, REMOTE_CENTRIFUGE_ID, AMOUNT
            ),
            abi.encode(value)
        );

        vm.mockCall(
            address(share),
            abi.encodeWithSelector(IERC20.transferFrom.selector, sender_, address(spoke), AMOUNT),
            abi.encode(true)
        );

        vm.mockCall(
            address(share), abi.encodeWithSelector(IERC20.approve.selector, registrar, AMOUNT), abi.encode(true)
        );

        vm.mockCall(
            address(registrar),
            abi.encodeWithSelector(IRegistrar.burn.selector, address(share), address(spoke), AMOUNT),
            abi.encode()
        );
    }

    function testErrShareTokenDoesNotExists() public {
        // Mock the share token lookup to revert
        vm.mockCallRevert(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encodeWithSelector(ISpokeRegistry.ShareTokenDoesNotExist.selector)
        );

        vm.prank(ANY);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        spoke.crosschainTransferShares{value: COST}(
            LOCAL_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 0, REFUND
        );
    }

    function testErrLocalTransferNotAllowed() public {
        _mockShareToken();

        vm.prank(ANY);
        vm.expectRevert(ISpoke.LocalTransferNotAllowed.selector);
        spoke.crosschainTransferShares{value: COST}(
            LOCAL_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 0, REFUND
        );
    }

    function testErrCrossChainTransferNotAllowed() public {
        _mockShareToken();
        _mockCrossTransferShare(ANY, false);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.CrossChainTransferNotAllowed.selector);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 0, REFUND
        );
    }

    function testCrossChainTransfer() public {
        _mockShareToken();
        _mockCrossTransferShare(ANY, true);
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                sender.sendInitiateTransferShares.selector,
                REMOTE_CENTRIFUGE_ID,
                POOL_A,
                SC_1,
                ANY.toBytes32(),
                RECEIVER.toBytes32(),
                AMOUNT,
                0,
                0,
                REFUND
            ),
            abi.encode()
        );

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.InitiateTransferShares(REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, ANY, ANY, RECEIVER.toBytes32(), AMOUNT);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 0, REFUND
        );
    }

    function testCrossChainTransferShortVersion() public {
        _mockShareToken();
        _mockCrossTransferShare(ANY, true);
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                sender.sendInitiateTransferShares.selector,
                REMOTE_CENTRIFUGE_ID,
                POOL_A,
                SC_1,
                ANY.toBytes32(),
                RECEIVER.toBytes32(),
                AMOUNT,
                0,
                100,
                ANY
            ),
            abi.encode()
        );

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.InitiateTransferShares(REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, ANY, ANY, RECEIVER.toBytes32(), AMOUNT);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 100, ANY
        );
    }

    /// @dev A ward (e.g. the SpokeV3_1_0 compatibility layer) may bridge on behalf of another owner; the
    ///      shares are pulled and burned from `owner`, not from the ward caller.
    function testCrossChainTransferOnBehalfByWard() public {
        _mockShareToken();
        _mockCrossTransferShare(ANY, true); // owner == ANY
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                sender.sendInitiateTransferShares.selector,
                REMOTE_CENTRIFUGE_ID,
                POOL_A,
                SC_1,
                ANY.toBytes32(),
                RECEIVER.toBytes32(),
                AMOUNT,
                0,
                0,
                REFUND
            ),
            abi.encode()
        );

        vm.prank(AUTH); // ward, owner != msg.sender
        vm.expectEmit();
        emit ISpoke.InitiateTransferShares(REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, ANY, ANY, RECEIVER.toBytes32(), AMOUNT);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 0, REFUND
        );
    }

    /// @dev A non-ward caller cannot bridge someone else's shares.
    function testErrNotAuthorizedOwnerMismatch() public {
        vm.prank(ANY); // not a ward, owner != msg.sender
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, RECEIVER, AMOUNT, 0, 0, REFUND
        );
    }
}

contract SpokeTestRegisterAsset is SpokeTest {
    AssetId immutable ASSET_ID_6909_2 = newAssetId(LOCAL_CENTRIFUGE_ID, 2);
    uint256 constant TOKEN_2 = 123;

    function testErrAssetMissingDecimalsERC20() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.AssetMissingDecimals.selector);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, address(0xbeef), 0, REFUND);
    }

    function testErrAssetMissingDecimalsERC6909() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.AssetMissingDecimals.selector);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, address(0xbeef), TOKEN_1, REFUND);
    }

    function testRegisterAssetZeroDecimalsERC20() public {
        _mockERC20(0);
        _mockNewAssetRegistration(erc20, 0, ASSET_ID_20);
        _mockSendRegisterAsset(ASSET_ID_20, 0);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(REMOTE_CENTRIFUGE_ID, ASSET_ID_20, erc20, 0, NAME, SYMBOL, 0, true);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc20, 0, REFUND);
    }

    function testRegisterAssetOneDecimalERC20() public {
        _mockERC20(1);
        _mockNewAssetRegistration(erc20, 0, ASSET_ID_20);
        _mockSendRegisterAsset(ASSET_ID_20, 1);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(REMOTE_CENTRIFUGE_ID, ASSET_ID_20, erc20, 0, NAME, SYMBOL, 1, true);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc20, 0, REFUND);
    }

    function testRegisterAssetZeroDecimalsERC6909() public {
        _mockERC6909(0, TOKEN_1);
        _mockNewAssetRegistration(erc6909, TOKEN_1, ASSET_ID_6909_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1, 0);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(REMOTE_CENTRIFUGE_ID, ASSET_ID_6909_1, erc6909, TOKEN_1, NAME, SYMBOL, 0, true);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1, REFUND);
    }

    function testRegisterAssetOneDecimalERC6909() public {
        _mockERC6909(1, TOKEN_1);
        _mockNewAssetRegistration(erc6909, TOKEN_1, ASSET_ID_6909_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1, 1);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(REMOTE_CENTRIFUGE_ID, ASSET_ID_6909_1, erc6909, TOKEN_1, NAME, SYMBOL, 1, true);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1, REFUND);
    }

    function testErrTooManyDecimalsERC20() public {
        _mockERC20(19);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.TooManyDecimals.selector);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc20, 0, REFUND);
    }

    function testRegisterAssetERC20() public {
        _mockERC20(DECIMALS);
        _mockNewAssetRegistration(erc20, 0, ASSET_ID_20);
        _mockSendRegisterAsset(ASSET_ID_20);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(REMOTE_CENTRIFUGE_ID, ASSET_ID_20, erc20, 0, NAME, SYMBOL, DECIMALS, true);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc20, 0, REFUND);
    }

    function testRegisterAssetERC6909() public {
        _mockERC6909(DECIMALS, TOKEN_1);
        _mockNewAssetRegistration(erc6909, TOKEN_1, ASSET_ID_6909_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(REMOTE_CENTRIFUGE_ID, ASSET_ID_6909_1, erc6909, TOKEN_1, NAME, SYMBOL, DECIMALS, true);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1, REFUND);
    }

    function testRegisterSameAssetTwice() public {
        _mockERC6909(DECIMALS, TOKEN_1);
        _mockExistingAssetRegistration(erc6909, TOKEN_1, ASSET_ID_6909_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(
            REMOTE_CENTRIFUGE_ID, ASSET_ID_6909_1, erc6909, TOKEN_1, NAME, SYMBOL, DECIMALS, false
        );
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1, REFUND);
    }
}

contract SpokeTestRequest is SpokeTest {
    function testErrInvalidRequestManager() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.requestManager.selector, POOL_A),
            abi.encode(address(0))
        );

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidRequestManager.selector);
        spoke.request{value: COST}(POOL_A, SC_1, ASSET_ID_20, PAYLOAD, EXTRA, false, REFUND);
    }

    function testErrNotAuthorized() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.requestManager.selector, POOL_A),
            abi.encode(requestManager)
        );

        vm.prank(AUTH);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.request{value: COST}(POOL_A, SC_1, ASSET_ID_20, PAYLOAD, EXTRA, false, REFUND);
    }

    function testRequestPaid() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.requestManager.selector, POOL_A),
            abi.encode(requestManager)
        );

        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                ISpokeMessageSender.sendRequest.selector, POOL_A, SC_1, ASSET_ID_20, PAYLOAD, EXTRA, false, REFUND
            ),
            abi.encode()
        );

        vm.prank(address(requestManager));
        spoke.request{value: COST}(POOL_A, SC_1, ASSET_ID_20, PAYLOAD, EXTRA, false, REFUND);
    }

    function testRequestUnpaid() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.requestManager.selector, POOL_A),
            abi.encode(requestManager)
        );

        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                ISpokeMessageSender.sendRequest.selector, POOL_A, SC_1, ASSET_ID_20, PAYLOAD, EXTRA, true, REFUND
            ),
            abi.encode()
        );

        vm.prank(address(requestManager));
        spoke.request{value: COST}(POOL_A, SC_1, ASSET_ID_20, PAYLOAD, EXTRA, true, REFUND);
    }
}
