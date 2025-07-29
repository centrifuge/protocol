// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../src/misc/types/D18.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC7575.sol";
import {IERC20Metadata} from "../../../src/misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {IGateway} from "../../../src/common/interfaces/IGateway.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../src/common/types/AssetId.sol";
import {IPoolEscrow} from "../../../src/common/interfaces/IPoolEscrow.sol";
import {VaultUpdateKind} from "../../../src/common/libraries/MessageLib.sol";
import {ITransferHook} from "../../../src/common/interfaces/ITransferHook.sol";
import {IRequestManager} from "../../../src/common/interfaces/IRequestManager.sol";
import {ISpokeMessageSender} from "../../../src/common/interfaces/IGatewaySenders.sol";
import {IPoolEscrowFactory} from "../../../src/common/factories/interfaces/IPoolEscrowFactory.sol";

import {Spoke, ISpoke} from "../../../src/spoke/Spoke.sol";
import {IShareToken} from "../../../src/spoke/interfaces/IShareToken.sol";
import {IVault, VaultKind} from "../../../src/spoke/interfaces/IVault.sol";
import {IVaultManager} from "../../../src/spoke/interfaces/IVaultManager.sol";
import {ITokenFactory} from "../../../src/spoke/factories/interfaces/ITokenFactory.sol";
import {IVaultFactory} from "../../../src/spoke/factories/interfaces/IVaultFactory.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract SpokeExt is Spoke {
    constructor(ITokenFactory factory, address deployer) Spoke(factory, deployer) {}

    function assetCounter() public view returns (uint64) {
        return _assetCounter;
    }

    function requestManager(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (IRequestManager) {
        return pools[poolId].shareClasses[scId].asset[assetId].manager;
    }

    function numVaults(PoolId poolId, ShareClassId scId, AssetId assetId) public view returns (uint32) {
        return pools[poolId].shareClasses[scId].asset[assetId].numVaults;
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
    IVaultFactory vaultFactory = IVaultFactory(address(new IsContract()));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    IGateway gateway = IGateway(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));
    IPoolEscrow escrow = IPoolEscrow(address(new IsContract()));
    IRequestManager requestManager = IRequestManager(address(new IsContract()));
    IVaultManager vaultManager = IVaultManager(address(new IsContract()));
    IVault vault = IVault(address(new IsContract()));

    address HOOK = makeAddr("hook");
    address HOOK2 = makeAddr("hook2");
    address NO_HOOK = address(0);

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("sc2"));

    AssetId immutable ASSET_ID_20 = newAssetId(LOCAL_CENTRIFUGE_ID, 1);
    AssetId immutable ASSET_ID_6909_1 = newAssetId(LOCAL_CENTRIFUGE_ID, 1);
    address erc20 = address(new IsContract());
    address erc6909 = address(new IsContract());
    uint256 constant TOKEN_1 = 23;

    uint8 constant DECIMALS = 18;
    string constant NAME = "name";
    string constant SYMBOL = "symbol";
    bytes32 constant SALT = "salt";
    bytes constant PAYLOAD = "payload";

    D18 immutable PRICE = d18(42e18);
    uint128 constant AMOUNT = 200;
    uint64 immutable MAX_AGE = 10_000;
    uint64 immutable PAST_OLD = 0;
    uint64 immutable PRESENT = MAX_AGE;
    uint64 immutable FUTURE = MAX_AGE + 1;

    uint16 constant INITIAL_GAS = 1000;
    uint16 constant GAS = 100;

    SpokeExt spoke = new SpokeExt(tokenFactory, AUTH);

    function setUp() public virtual {
        vm.deal(ANY, INITIAL_GAS);

        vm.startPrank(AUTH);
        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(sender));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));

        vm.stopPrank();
        vm.warp(MAX_AGE);

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

        vm.mockCall(address(share), abi.encodeWithSelector(share.name.selector), abi.encode(NAME));
        vm.mockCall(address(share), abi.encodeWithSelector(share.symbol.selector), abi.encode(SYMBOL));
        vm.mockCall(address(share), abi.encodeWithSelector(share.hook.selector), abi.encode(HOOK));

        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_A));
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.scId.selector), abi.encode(SC_1));
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.manager.selector), abi.encode(vaultManager));
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.vaultKind.selector), abi.encode(VaultKind.Async));
    }

    function _mockPayment(address who) internal {
        vm.mockCall(
            address(gateway), GAS, abi.encodeWithSelector(gateway.startTransactionPayment.selector, who), abi.encode()
        );

        vm.mockCall(address(gateway), abi.encodeWithSelector(gateway.endTransactionPayment.selector), abi.encode());
    }

    function _mockValidShareHook(address hook) internal {
        vm.mockCall(
            hook,
            abi.encodeWithSelector(IERC165.supportsInterface.selector, type(ITransferHook).interfaceId),
            abi.encode(true)
        );
        vm.mockCall(
            address(share), abi.encodeWithSignature("file(bytes32,address)", bytes32("hook"), hook), abi.encode()
        );
        vm.mockCall(
            address(hook),
            abi.encodeWithSelector(ITransferHook(hook).updateRestriction.selector, share, PAYLOAD),
            abi.encode()
        );
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
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(sender.sendRegisterAsset.selector, REMOTE_CENTRIFUGE_ID, assetId, DECIMALS),
            abi.encode()
        );
    }

    function _mockVaultManager(AssetId assetId, address asset, uint256 tokenId) internal {
        vm.mockCall(
            address(vaultManager),
            abi.encodeWithSelector(vaultManager.addVault.selector, POOL_A, SC_1, assetId, vault, asset, tokenId),
            abi.encode()
        );

        vm.mockCall(
            address(vaultManager),
            abi.encodeWithSelector(vaultManager.removeVault.selector, POOL_A, SC_1, assetId, vault, asset, tokenId),
            abi.encode()
        );
    }

    function _mockVaultFactory(address asset, uint256 tokenId) internal {
        vm.mockCall(
            address(vaultFactory),
            abi.encodeWithSelector(
                vaultFactory.newVault.selector, POOL_A, SC_1, asset, tokenId, share, new address[](0)
            ),
            abi.encode(vault)
        );
    }

    function _utilRegisterAsset(address asset) internal {
        _mockPayment(ANY);

        if (asset == erc20) _mockERC20(DECIMALS);
        if (asset == erc20) _mockSendRegisterAsset(ASSET_ID_20);

        if (asset == erc6909) _mockERC6909(DECIMALS, TOKEN_1);
        if (asset == erc6909) _mockSendRegisterAsset(ASSET_ID_6909_1);

        uint256 tokenId = 0;
        if (asset == erc6909) tokenId = TOKEN_1;

        vm.prank(ANY);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, asset, tokenId);
    }

    function _utilAddPoolAndShareClass(address hook) internal {
        if (hook == HOOK) _mockValidShareHook(HOOK);

        vm.prank(AUTH);
        spoke.addPool(POOL_A);

        vm.prank(AUTH);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, hook);
    }

    function _utilDeployVault(address asset) internal {
        uint256 tokenId = 0;
        if (asset == erc6909) tokenId = TOKEN_1;

        AssetId assetId = ASSET_ID_20;
        if (asset == erc6909) assetId = ASSET_ID_6909_1;

        _mockVaultFactory(asset, tokenId);

        vm.prank(AUTH);
        spoke.deployVault(POOL_A, SC_1, assetId, vaultFactory);
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

    function _mockCrossTransferShare(address sender, bool value) public {
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

    function testErrShareTokenDoesNotExists() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.crosschainTransferShares{value: GAS}(LOCAL_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, 0);
    }

    function testErrLocalTransferNotAllowed() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.LocalTransferNotAllowed.selector);
        spoke.crosschainTransferShares{value: GAS}(LOCAL_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, 0);
    }

    function testErrCrossChainTransferNotAllowed() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockCrossTransferShare(ANY, false);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.CrossChainTransferNotAllowed.selector);
        spoke.crosschainTransferShares{value: GAS}(REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, 0);
    }

    function testCrossChainTransfer() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockCrossTransferShare(ANY, true);
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
    AssetId immutable ASSET_ID_6909_2 = newAssetId(LOCAL_CENTRIFUGE_ID, 2);
    uint256 constant TOKEN_2 = 123;

    function setUp() public override {
        super.setUp();
        _mockPayment(ANY);
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
        _mockERC20(DECIMALS);
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
        _mockERC6909(DECIMALS, TOKEN_1);
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
        _mockERC6909(DECIMALS, TOKEN_1);
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
        _mockERC6909(DECIMALS, TOKEN_1);
        _mockSendRegisterAsset(ASSET_ID_6909_1);
        vm.prank(ANY);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_1);

        _mockERC6909(DECIMALS, TOKEN_2);
        _mockSendRegisterAsset(ASSET_ID_6909_2);
        vm.prank(ANY);
        spoke.registerAsset{value: GAS}(REMOTE_CENTRIFUGE_ID, erc6909, TOKEN_2);

        assertEq(spoke.assetCounter(), 2);
    }
}

contract SpokeTestRequest is SpokeTest {
    function testErrNotAuthorized() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.request(POOL_A, SC_1, ASSET_ID_20, PAYLOAD);
    }

    function testErrShareTokenDoesNotExists() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.request(POOL_A, SC_1, ASSET_ID_20, PAYLOAD);
    }

    function testRequest() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.setRequestManager(POOL_A, SC_1, ASSET_ID_20, requestManager);

        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(ISpokeMessageSender.sendRequest.selector, POOL_A, SC_1, ASSET_ID_20, PAYLOAD),
            abi.encode()
        );

        vm.prank(address(requestManager));
        spoke.request(POOL_A, SC_1, ASSET_ID_20, PAYLOAD);
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
        assertEq(spoke.isPoolActive(POOL_A), true);
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

        _mockValidShareHook(HOOK);

        vm.prank(AUTH);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, HOOK);
    }
}

contract SpokeTestLinkToken is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.linkToken(POOL_A, SC_1, share);
    }

    function testLinkToken() public {
        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.AddShareClass(POOL_A, SC_1, share);
        spoke.linkToken(POOL_A, SC_1, share);

        assertEq(address(spoke.shareToken(POOL_A, SC_1)), address(share));
    }
}

contract SpokeTestSetRequestManager is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.setRequestManager(POOL_A, SC_1, ASSET_ID_20, requestManager);
    }

    function testErrShareTokenDoesNotExists() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.setRequestManager(POOL_A, SC_1, ASSET_ID_20, requestManager);
    }

    function testErrMoreThanZeroLinkedVaults() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        _mockVaultManager(ASSET_ID_6909_1, erc6909, TOKEN_1);

        vm.prank(AUTH);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.MoreThanZeroLinkedVaults.selector);
        spoke.setRequestManager(POOL_A, SC_1, ASSET_ID_6909_1, requestManager);
    }

    function testSetRequestManager() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.SetRequestManager(POOL_A, SC_1, ASSET_ID_20, requestManager);
        spoke.setRequestManager(POOL_A, SC_1, ASSET_ID_20, requestManager);

        assertEq(address(spoke.requestManager(POOL_A, SC_1, ASSET_ID_20)), address(requestManager));
    }
}

contract SpokeTestUpdateShareMetadata is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.updateShareMetadata(POOL_A, SC_1, NAME, SYMBOL);
    }

    function testErrOldMetadata() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.OldMetadata.selector);
        spoke.updateShareMetadata(POOL_A, SC_1, NAME, SYMBOL);
    }

    function testUpdateShareMetadata() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        string memory file = "file(bytes32,string)";
        vm.mockCall(address(share), abi.encodeWithSignature(file, bytes32("name"), "name2"), abi.encode());
        vm.mockCall(address(share), abi.encodeWithSignature(file, bytes32("symbol"), "symbol2"), abi.encode());

        vm.prank(AUTH);
        spoke.updateShareMetadata(POOL_A, SC_1, "name2", "symbol2");
    }
}

contract SpokeTestUpdateShareHook is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.updateShareHook(POOL_A, SC_1, HOOK);
    }

    function testErrOldHook() public {
        _utilAddPoolAndShareClass(HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.OldHook.selector);
        spoke.updateShareHook(POOL_A, SC_1, HOOK);
    }

    function testUpdateShareHook() public {
        _utilAddPoolAndShareClass(HOOK);

        _mockValidShareHook(HOOK2);
        vm.prank(AUTH);
        spoke.updateShareHook(POOL_A, SC_1, HOOK2);
    }
}

contract SpokeTestUpdateRestriction is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.updateRestriction(POOL_A, SC_1, PAYLOAD);
    }

    function testErrInvalidHook() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.mockCall(address(share), abi.encodeWithSelector(share.hook.selector), abi.encode(NO_HOOK));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidHook.selector);
        spoke.updateRestriction(POOL_A, SC_1, PAYLOAD);
    }

    function testUpdateRestriction() public {
        _utilAddPoolAndShareClass(HOOK);

        vm.prank(AUTH);
        spoke.updateRestriction(POOL_A, SC_1, PAYLOAD);
    }
}

contract SpokeTestExecuteTransferShares is SpokeTest {
    using CastLib for *;

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.executeTransferShares(POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT);
    }

    function testExecuteTransferShares() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.mockCall(address(share), abi.encodeWithSelector(share.mint.selector, RECEIVER, AMOUNT), abi.encode());

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.ExecuteTransferShares(POOL_A, SC_1, RECEIVER, AMOUNT);
        spoke.executeTransferShares(POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT);
    }
}

contract SpokeTestUpdatePricePoolPerShare is SpokeTest {
    using CastLib for *;

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, PRESENT);
    }

    function testErrShareTokenDoesNotExists() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, PRESENT);
    }

    function testErrCannotSetOlderPrice() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.CannotSetOlderPrice.selector);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, PRESENT);
    }

    function testUpdatePricePoolPerShare() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UpdateSharePrice(POOL_A, SC_1, PRICE, FUTURE);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        (uint64 computeAt, uint64 maxAge, uint64 validUntil) = spoke.markersPricePoolPerShare(POOL_A, SC_1);
        assertEq(computeAt, FUTURE);
        assertEq(maxAge, type(uint64).max);
        assertEq(validUntil, type(uint64).max);
    }

    function testMaxAgeNotOverwritenAfterUpdatingPrice() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);

        vm.prank(AUTH);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        (, uint64 maxAge,) = spoke.markersPricePoolPerShare(POOL_A, SC_1);
        assertEq(maxAge, MAX_AGE);
    }
}

contract SpokeTestUpdatePricePoolPerAsset is SpokeTest {
    using CastLib for *;

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, PRESENT);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, FUTURE);
    }

    function testErrShareTokenDoesNotExists() public {
        _utilRegisterAsset(erc6909);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, PRESENT);
    }

    function testErrCannotSetOlderPrice() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, FUTURE);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.CannotSetOlderPrice.selector);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, PRESENT);
    }

    function testUpdatePricePoolPerAsset() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UpdateAssetPrice(POOL_A, SC_1, erc6909, TOKEN_1, PRICE, FUTURE);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, FUTURE);

        (uint64 computeAt, uint64 maxAge, uint64 validUntil) =
            spoke.markersPricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1);
        assertEq(computeAt, FUTURE);
        assertEq(maxAge, type(uint64).max);
        assertEq(validUntil, type(uint64).max);
    }

    function testMaxAgeNotOverwritenAfterUpdatingPrice() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID_6909_1, MAX_AGE);

        vm.prank(AUTH);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, FUTURE);

        (, uint64 maxAge,) = spoke.markersPricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1);
        assertEq(maxAge, MAX_AGE);
    }
}

contract SpokeTestSetMaxSharePriceAge is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);
    }

    function testErrShareTokenDoesNotExists() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);
    }

    function testSetMaxSharePriceAge() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UpdateMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);
        spoke.setMaxSharePriceAge(POOL_A, SC_1, MAX_AGE);

        (, uint64 maxAge, uint64 validUntil) = spoke.markersPricePoolPerShare(POOL_A, SC_1);
        assertEq(maxAge, MAX_AGE);
        assertEq(validUntil, MAX_AGE);
    }
}

contract SpokeTestSetMaxAssetPriceAge is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID_6909_1, MAX_AGE);
    }

    function testErrShareTokenDoesNotExists() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID_6909_1, MAX_AGE);
    }

    function testErrUnknownAsset() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        spoke.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID_6909_1, MAX_AGE);
    }

    function testSetMaxAssetPriceAge() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UpdateMaxAssetPriceAge(POOL_A, SC_1, erc6909, TOKEN_1, MAX_AGE);
        spoke.setMaxAssetPriceAge(POOL_A, SC_1, ASSET_ID_6909_1, MAX_AGE);

        (, uint64 maxAge, uint64 validUntil) = spoke.markersPricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1);
        assertEq(maxAge, MAX_AGE);
        assertEq(validUntil, MAX_AGE);
    }
}

contract SpokeTestRequestCallback is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.requestCallback(POOL_A, SC_1, ASSET_ID_6909_1, PAYLOAD);
    }

    function testErrShareTokenDoesNotExists() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.requestCallback(POOL_A, SC_1, ASSET_ID_6909_1, PAYLOAD);
    }

    function testErrInvalidRequestManager() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidRequestManager.selector);
        spoke.requestCallback(POOL_A, SC_1, ASSET_ID_6909_1, PAYLOAD);
    }

    function testRequestCallback() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.setRequestManager(POOL_A, SC_1, ASSET_ID_6909_1, requestManager);

        vm.mockCall(
            address(requestManager),
            abi.encodeWithSelector(requestManager.callback.selector, POOL_A, SC_1, ASSET_ID_6909_1, PAYLOAD),
            abi.encode()
        );

        vm.prank(AUTH);
        spoke.requestCallback(POOL_A, SC_1, ASSET_ID_6909_1, PAYLOAD);
    }
}

contract SpokeTestDeployVault is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrShareTokenDoesNotExists() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrUnknownAsset() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        spoke.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testDeployVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockVaultFactory(erc6909, TOKEN_1);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.DeployVault(POOL_A, SC_1, erc6909, TOKEN_1, vaultFactory, vault, VaultKind.Async);
        IVault returnedVault = spoke.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);

        assertEq(address(returnedVault), address(vault));
        assertEq(spoke.vaultDetails(vault).assetId.raw(), ASSET_ID_6909_1.raw());
        assertEq(spoke.vaultDetails(vault).asset, erc6909);
        assertEq(spoke.vaultDetails(vault).tokenId, TOKEN_1);
        assertEq(spoke.vaultDetails(vault).isLinked, false);
    }
}

contract SpokeTestLinkVault is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByShareClassId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.scId.selector), abi.encode(SC_2));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrShareTokenDoesNotExists() public {
        _utilRegisterAsset(erc6909);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyLinkedVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        _mockVaultManager(ASSET_ID_6909_1, erc6909, TOKEN_1);

        vm.prank(AUTH);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.AlreadyLinkedVault.selector);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testLinkVaultERC6909() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        _mockVaultManager(ASSET_ID_6909_1, erc6909, TOKEN_1);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.LinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(spoke.numVaults(POOL_A, SC_1, ASSET_ID_6909_1), 1);
        assertEq(spoke.isLinked(vault), true);
    }

    function testLinkVaultERC20() public {
        _utilRegisterAsset(erc20);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc20);

        _mockVaultManager(ASSET_ID_20, erc20, 0);

        vm.mockCall(address(share), abi.encodeWithSelector(share.updateVault.selector, erc20, vault), abi.encode());

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.LinkVault(POOL_A, SC_1, erc20, 0, vault);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }
}

contract SpokeTestUnlinkVault is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByShareClassId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.scId.selector), abi.encode(SC_2));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrShareTokenDoesNotExists() public {
        _utilRegisterAsset(erc6909);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyUnlinkedVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockVaultManager(ASSET_ID_6909_1, erc6909, TOKEN_1);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.AlreadyUnlinkedVault.selector);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testUnlinkVaultERC6909() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        _mockVaultManager(ASSET_ID_6909_1, erc6909, TOKEN_1);

        vm.prank(AUTH);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UnlinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(spoke.numVaults(POOL_A, SC_1, ASSET_ID_6909_1), 0);
        assertEq(spoke.isLinked(vault), false);
    }

    function testUnlinkVaultERC20() public {
        _utilRegisterAsset(erc20);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc20);

        _mockVaultManager(ASSET_ID_20, erc20, 0);

        vm.mockCall(address(share), abi.encodeWithSelector(share.updateVault.selector, erc20, vault), abi.encode());

        vm.prank(AUTH);
        spoke.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);

        vm.mockCall(address(share), abi.encodeWithSelector(share.updateVault.selector, erc20, address(0)), abi.encode());

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UnlinkVault(POOL_A, SC_1, erc20, 0, vault);
        spoke.unlinkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }
}

contract SpokeTestUpdateVault is SpokeTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vaultFactory), VaultUpdateKind.DeployAndLink);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        spoke.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vaultFactory), VaultUpdateKind.Link);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        spoke.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vaultFactory), VaultUpdateKind.Unlink);
    }

    function testDeployAndLinkAndUnlinkAndLink() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockVaultFactory(erc6909, TOKEN_1);
        _mockVaultManager(ASSET_ID_6909_1, erc6909, TOKEN_1);

        vm.prank(AUTH);
        spoke.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vaultFactory), VaultUpdateKind.DeployAndLink);

        assertEq(spoke.isLinked(vault), true, "deploy and linked");

        vm.prank(AUTH);
        spoke.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault), VaultUpdateKind.Unlink);

        assertEq(spoke.isLinked(vault), false, "unlinked");

        vm.prank(AUTH);
        spoke.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault), VaultUpdateKind.Link);

        assertEq(spoke.isLinked(vault), true, "linked again");
    }
}

contract SpokeTestPricePoolPerShare is SpokeTest {
    function testErrShareTokenDoesNotExists() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.pricePoolPerShare(POOL_A, SC_1, false);
    }

    function testErrInvalidPrice() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.InvalidPrice.selector);
        spoke.pricePoolPerShare(POOL_A, SC_1, true);
    }

    function testPricePoolPerShareWithoutValidity() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(ANY);
        D18 price = spoke.pricePoolPerShare(POOL_A, SC_1, false);

        assertEq(price.raw(), 0);
    }

    function testPricePoolPerShareWithValidity() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        vm.prank(ANY);
        D18 price = spoke.pricePoolPerShare(POOL_A, SC_1, true);

        assertEq(price.raw(), PRICE.raw());
    }
}

contract SpokeTestPricePoolPerAsset is SpokeTest {
    function testErrAssetTokenDoesNotExists() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, false);
    }

    function testErrInvalidPrice() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.InvalidPrice.selector);
        spoke.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, true);
    }

    function testPricePoolPerAssetWithoutValidity() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(ANY);
        D18 price = spoke.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, false);

        assertEq(price.raw(), 0);
    }

    function testPricePoolPerAssetWithValidity() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, FUTURE);

        vm.prank(ANY);
        D18 price = spoke.pricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, true);

        assertEq(price.raw(), PRICE.raw());
    }
}

contract SpokeTestPricesPoolPer is SpokeTest {
    function testErrAssetTokenDoesNotExists() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.pricesPoolPer(POOL_A, SC_1, ASSET_ID_6909_1, false);
    }

    function testErrInvalidPrice() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.InvalidPrice.selector);
        spoke.pricesPoolPer(POOL_A, SC_1, ASSET_ID_6909_1, true);
    }

    function testErrInvalidPriceOnlyAsset() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE, FUTURE);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.InvalidPrice.selector);
        spoke.pricesPoolPer(POOL_A, SC_1, ASSET_ID_6909_1, true);
    }

    function testErrInvalidPriceOnlyShare() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, FUTURE);

        vm.prank(ANY);
        vm.expectRevert(ISpoke.InvalidPrice.selector);
        spoke.pricesPoolPer(POOL_A, SC_1, ASSET_ID_6909_1, true);
    }

    function testPricePoolPerAssetWithoutValidity() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(ANY);
        (D18 assetPrice, D18 sharePrice) = spoke.pricesPoolPer(POOL_A, SC_1, ASSET_ID_6909_1, false);

        assertEq(assetPrice.raw(), 0);
        assertEq(sharePrice.raw(), 0);
    }

    function testPricePoolPerAssetWithValidity() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        spoke.updatePricePoolPerAsset(POOL_A, SC_1, ASSET_ID_6909_1, PRICE, FUTURE);

        vm.prank(AUTH);
        spoke.updatePricePoolPerShare(POOL_A, SC_1, PRICE + d18(1), FUTURE);

        vm.prank(ANY);
        (D18 assetPrice, D18 sharePrice) = spoke.pricesPoolPer(POOL_A, SC_1, ASSET_ID_6909_1, true);

        assertEq(assetPrice.raw(), PRICE.raw());
        assertEq(sharePrice.raw(), (PRICE + d18(1)).raw());
    }
}

contract SpokeTestVaultDetails is SpokeTest {
    function testErrUnknownVault() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        spoke.vaultDetails(vault);
    }
}
