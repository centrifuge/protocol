// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";
import {IERC165} from "src/misc/interfaces/IERC7575.sol";

import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import {ITransferHook} from "src/common/interfaces/ITransferHook.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {ISpokeMessageSender} from "src/common/interfaces/IGatewaySenders.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IPoolEscrowFactory} from "src/common/factories/interfaces/IPoolEscrowFactory.sol";
import {IPoolEscrow} from "src/common/interfaces/IPoolEscrow.sol";

import {ITokenFactory} from "src/spoke/factories/interfaces/ITokenFactory.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {Spoke, ISpoke} from "src/spoke/Spoke.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract SpokeExt is Spoke {
    constructor(ITokenFactory factory, address deployer) Spoke(factory, deployer) {}

    function assetCounter() public view returns (uint64) {
        return _assetCounter;
    }
}

contract SpokeTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable RECEIVER = makeAddr("RECEIVER");

    ITokenFactory tokenFactory = ITokenFactory(makeAddr("tokenFactory"));
    IPoolEscrowFactory poolEscrowFactory = IPoolEscrowFactory(address(new IsContract()));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    IGateway gateway = IGateway(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));
    IPoolEscrow escrow = IPoolEscrow(address(new IsContract()));
    address HOOK = makeAddr("hook");
    address NO_HOOK = address(0);

    AssetId immutable ASSET_ID_20 = newAssetId(LOCAL_CENTRIFUGE_ID, 1);
    AssetId immutable ASSET_ID_6909_1 = newAssetId(LOCAL_CENTRIFUGE_ID, 1);
    AssetId immutable ASSET_ID_6909_2 = newAssetId(LOCAL_CENTRIFUGE_ID, 2);
    address erc20 = address(new IsContract());
    address erc6909 = address(new IsContract());
    uint256 constant TOKEN_1 = 23;
    uint256 constant TOKEN_2 = 123;

    uint8 constant DECIMALS = 18;
    string constant NAME = "name";
    string constant SYMBOL = "symbol";
    bytes32 constant SALT = "salt";

    PoolId constant POOL_A = PoolId.wrap(1);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("scId"));
    uint16 constant INITIAL_GAS = 1000;
    uint16 constant GAS = 100;
    uint128 constant AMOUNT = 200;

    SpokeExt spoke = new SpokeExt(tokenFactory, AUTH);

    function setUp() public virtual {
        vm.deal(ANY, INITIAL_GAS);

        vm.startPrank(AUTH);
        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(sender));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));

        vm.stopPrank();

        _mockBaseStuff();
    }

    function _mockBaseStuff() private {
        vm.mockCall(
            address(sender), abi.encodeWithSelector(sender.localCentrifugeId.selector), abi.encode(LOCAL_CENTRIFUGE_ID)
        );

        vm.mockCall(
            address(poolEscrowFactory),
            abi.encodeWithSelector(poolEscrowFactory.escrow.selector, POOL_A),
            abi.encode(escrow)
        );

        vm.mockCall(
            address(poolEscrowFactory),
            abi.encodeWithSelector(poolEscrowFactory.newEscrow.selector, POOL_A),
            abi.encode(escrow)
        );

        vm.mockCall(
            address(gateway), abi.encodeWithSelector(gateway.setRefundAddress.selector, POOL_A, escrow), abi.encode()
        );

        vm.mockCall(
            address(tokenFactory),
            abi.encodeWithSelector(tokenFactory.newToken.selector, NAME, SYMBOL, DECIMALS, SALT),
            abi.encode(share)
        );
    }

    function _mockPayment(address who) internal {
        vm.mockCall(
            address(gateway), GAS, abi.encodeWithSelector(gateway.startTransactionPayment.selector, who), abi.encode()
        );

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endTransactionPayment.selector), abi.encode());
    }

    function testConstructor() public view {
        assertEq(address(spoke.tokenFactory()), address(tokenFactory));
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
        emit ISpoke.File("gateway", address(23));
        spoke.file("gateway", address(23));
        assertEq(address(spoke.gateway()), address(23));

        spoke.file("sender", address(42));
        assertEq(address(spoke.sender()), address(42));

        spoke.file("tokenFactory", address(88));
        assertEq(address(spoke.tokenFactory()), address(88));

        spoke.file("poolEscrowFactory", address(99));
        assertEq(address(spoke.poolEscrowFactory()), address(99));
    }
}

contract SpokeTestCrosschainTransferShares is SpokeTest {
    using CastLib for *;

    function setUp() public override {
        super.setUp();
        _mockPayment(ANY);
    }

    function _mockShare(address sender, bool value) public {
        vm.mockCall(
            address(share),
            abi.encodeWithSelector(share.checkTransferRestriction.selector, sender, REMOTE_CENTRIFUGE_ID, AMOUNT),
            abi.encode(value)
        );

        vm.mockCall(
            address(share),
            abi.encodeWithSelector(share.authTransferFrom.selector, sender, sender, spoke, AMOUNT),
            abi.encode(true)
        );

        vm.mockCall(address(share), abi.encodeWithSelector(share.burn.selector, spoke, AMOUNT), abi.encode());
    }

    function testErrLocalTransferNotAllowed() public {
        vm.prank(AUTH);
        spoke.linkToken(POOL_A, SC_1, share);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.LocalTransferNotAllowed.selector);
        spoke.crosschainTransferShares{value: GAS}(LOCAL_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, 0);
    }

    function testErrCrossChainTransferNotAllowed() public {
        vm.prank(AUTH);
        spoke.linkToken(POOL_A, SC_1, share);

        _mockShare(ANY, false);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.CrossChainTransferNotAllowed.selector);
        spoke.crosschainTransferShares{value: GAS}(REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, 0);
    }

    function testCrossChainTransfer() public {
        vm.prank(AUTH);
        spoke.linkToken(POOL_A, SC_1, share);

        _mockShare(ANY, true);
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(
                sender.sendInitiateTransferShares.selector,
                REMOTE_CENTRIFUGE_ID,
                POOL_A,
                SC_1,
                RECEIVER.toBytes32(),
                AMOUNT,
                0
            ),
            abi.encode()
        );

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.InitiateTransferShares(REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, ANY, RECEIVER.toBytes32(), AMOUNT);
        spoke.crosschainTransferShares{value: GAS}(REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, 0);
    }
}

contract SpokeTestRegisterAsset is SpokeTest {
    function setUp() public override {
        super.setUp();
        _mockPayment(ANY);
    }

    function _mockERC20(uint8 decimals) private {
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(decimals));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode(NAME));
        vm.mockCall(address(erc20), abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode(SYMBOL));
    }

    function _mockERC6909(uint8 decimals, uint256 token) private {
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

    function _mockSendRegisterAsset(AssetId assetId) private {
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(sender.sendRegisterAsset.selector, REMOTE_CENTRIFUGE_ID, assetId, DECIMALS),
            abi.encode()
        );
    }

    function testErrAssetMissingDecimalsERC20() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.AssetMissingDecimals.selector);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, address(0xbeef), 0);
    }

    function testErrAssetMissingDecimalsERC6909() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.AssetMissingDecimals.selector);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, address(0xbeef), TOKEN_1);
    }

    function testErrTooFewDecimalsERC20() public {
        _mockERC20(1);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.TooFewDecimals.selector);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc20, 0);
    }

    function testErrTooFewDecimalsERC6909() public {
        _mockERC6909(1, TOKEN_1);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.TooFewDecimals.selector);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1);
    }

    function testErrTooManyDecimalsERC20() public {
        _mockERC20(19);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.TooManyDecimals.selector);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc20, 0);
    }

    function testErrTooManyDecimalsERC6909() public {
        _mockERC6909(19, TOKEN_1);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.TooManyDecimals.selector);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1);
    }

    function testRegisterAssetERC20() public {
        _mockERC20(18);
        _mockSendRegisterAsset(ASSET_ID_20);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(ASSET_ID_20, erc20, 0, NAME, SYMBOL, DECIMALS, true);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc20, 0);

        assertEq(spoke.assetCounter(), 1);
        assertEq(spoke.assetToId(erc20, 0).raw(), ASSET_ID_20.raw());

        (address asset, uint256 tokenId) = spoke.idToAsset(ASSET_ID_20);
        assertEq(asset, erc20);
        assertEq(tokenId, 0);
    }

    function testRegisterAssetERC6909() public {
        _mockERC6909(18, TOKEN_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(ASSET_ID_6909_1, erc6909, TOKEN_1, NAME, SYMBOL, DECIMALS, true);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1);

        assertEq(spoke.assetCounter(), 1);
        assertEq(spoke.assetToId(erc6909, TOKEN_1).raw(), ASSET_ID_6909_1.raw());

        (address asset, uint256 tokenId) = spoke.idToAsset(ASSET_ID_6909_1);
        assertEq(asset, erc6909);
        assertEq(tokenId, TOKEN_1);
    }

    function testRegisterSameAssetTwice() public {
        _mockERC6909(18, TOKEN_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1);

        vm.prank(ANY);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1);

        vm.prank(ANY);
        vm.expectEmit();
        emit ISpoke.RegisterAsset(ASSET_ID_6909_1, erc6909, TOKEN_1, NAME, SYMBOL, DECIMALS, false);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1);

        assertEq(spoke.assetCounter(), 1);
    }

    function testRegisterDifferentAssetTwice() public {
        _mockERC6909(18, TOKEN_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1);
        vm.prank(ANY);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1);

        _mockERC6909(18, TOKEN_2);
        _mockSendRegisterAsset(ASSET_ID_6909_2);
        vm.prank(ANY);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_2);

        assertEq(spoke.assetCounter(), 2);
    }
}

contract SpokeTestAddPool is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.addPool(POOL_A);
    }

    function testErrPoolAlreadyAdded() public {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.PoolAlreadyAdded.selector);
        spoke.addPool(POOL_A);
    }

    function testAddPool() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.AddPool(POOL_A);
        spoke.addPool(POOL_A);

        assertEq(spoke.pools(POOL_A), block.timestamp);
    }
}

contract SpokeTestAddShareClass is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, NO_HOOK);
    }

    function testErrInvalidPool() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidPool.selector);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, NO_HOOK);
    }

    function testErrTooFewDecimals() public {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.TooFewDecimals.selector);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, 1, SALT, NO_HOOK);
    }

    function testErrTooManyDecimals() public {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.TooManyDecimals.selector);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, 19, SALT, NO_HOOK);
    }

    function testErrShareClassAlreadyRegistered() public {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.prank(AUTH);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareClassAlreadyRegistered.selector);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, NO_HOOK);
    }

    function testAddShareClass() public {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.AddShareClass(POOL_A, SC_1, share);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, NO_HOOK);

        assertEq(address(spoke.shareToken(POOL_A, SC_1)), address(share));
    }

    function testErrInvalidHook() public {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidHook.selector);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, HOOK);
    }

    function testAddShareClassWithHook() public {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.mockCall(
            HOOK,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ITransferHook).interfaceId),
            abi.encode(true)
        );
        vm.mockCall(
            address(share), abi.encodeWithSignature("file(bytes32,address)", bytes32("hook"), HOOK), abi.encode()
        );

        vm.prank(AUTH);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, HOOK);
    }
}
