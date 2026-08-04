// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {IEscrow} from "../../../../src/misc/interfaces/IEscrow.sol";
import {IERC20, IERC20Metadata} from "../../../../src/misc/interfaces/IERC20.sol";
import {IERC6909, IERC6909MetadataExt, TransferFailed} from "../../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {Spoke, ISpoke} from "../../../../src/core/spoke/Spoke.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {SnapshotQueue} from "../../../../src/core/spoke/SnapshotQueue.sol";
import {IGateway} from "../../../../src/core/messaging/interfaces/IGateway.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {ISnapshotQueue} from "../../../../src/core/spoke/interfaces/ISnapshotQueue.sol";
import {ISpokeRegistry} from "../../../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {ISpokeMessageSender} from "../../../../src/core/messaging/interfaces/IGatewaySenders.sol";
import {ISpokeRequestManager} from "../../../../src/core/spoke/interfaces/ISpokeRequestManager.sol";
import {IPoolEscrowProvider} from "../../../../src/core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import "forge-std/Test.sol";

import {IShareToken} from "../../../../src/token/interfaces/IShareToken.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract SpokeTest is Test {
    using CastLib for *;

    bytes4 constant SEND_UPDATE_ASSETS_SELECTOR = ISpokeMessageSender.sendUpdateAssets.selector;

    uint16 constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable RECEIVER = makeAddr("RECEIVER");
    address immutable REFUND = makeAddr("REFUND");
    address immutable MANAGER = makeAddr("MANAGER");
    address immutable SENDER = makeAddr("SENDER");
    address immutable FROM = makeAddr("FROM");
    address immutable TO = makeAddr("TO");
    address immutable RESERVER = makeAddr("RESERVER");

    IGateway gateway = IGateway(address(new IsContract()));
    IPoolEscrowProvider escrowProvider = IPoolEscrowProvider(makeAddr("EscrowProvider"));
    ISpokeRegistry spokeRegistry = ISpokeRegistry(address(new IsContract()));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));
    IRegistrar registrar = IRegistrar(address(new IsContract()));
    ISpokeRequestManager requestManager = ISpokeRequestManager(address(new IsContract()));

    address erc20 = address(new IsContract());
    address erc6909 = address(new IsContract());
    address escrow = address(new IsContract());
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

    uint256 constant COST = 123;
    uint128 constant EXTRA = 456;
    uint128 constant EXTRA_GAS = 0;
    bytes32 constant RESERVE_REASON = bytes32(uint256(1));
    bool constant IS_ISSUANCE = true;
    bool constant IS_DEPOSIT = true;
    bool constant IS_SNAPSHOT = true;

    SnapshotQueue snapshotQueue = new SnapshotQueue(address(this));
    Spoke spoke = new Spoke(gateway, snapshotQueue, spokeRegistry, escrowProvider, AUTH);

    function setUp() public virtual {
        vm.deal(ANY, 1 ether);
        vm.deal(AUTH, 1 ether);
        vm.deal(MANAGER, 1 ether);
        vm.deal(address(requestManager), 1 ether);

        snapshotQueue.rely(address(spoke));

        vm.prank(AUTH);
        spoke.file("sender", address(sender));

        vm.warp(MAX_AGE);

        _mockBaseStuff();
    }

    function _mockBaseStuff() private {
        vm.mockCall(
            address(sender), abi.encodeWithSelector(sender.localCentrifugeId.selector), abi.encode(LOCAL_CENTRIFUGE_ID)
        );
        // Default: only MANAGER is a balance-sheet manager, no policy installed.
        vm.mockCall(address(spokeRegistry), abi.encodeWithSelector(ISpokeRegistry.manager.selector), abi.encode(false));
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.manager.selector, POOL_A, MANAGER),
            abi.encode(true)
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.policy.selector, POOL_A),
            abi.encode(address(0))
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(bytes4(keccak256("assetToId(address,uint256,bool)")), erc20, 0),
            abi.encode(ASSET_ID_20)
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(bytes4(keccak256("assetToId(address,uint256,bool)")), erc6909, TOKEN_1),
            abi.encode(ASSET_ID_6909_1)
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(share, registrar)
        );
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, POOL_A, SC_1),
            abi.encode(share)
        );
        vm.mockCall(
            address(escrowProvider),
            abi.encodeWithSelector(IPoolEscrowProvider.escrow.selector, POOL_A),
            abi.encode(escrow)
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
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(sender.sendRegisterAsset.selector, REMOTE_CENTRIFUGE_ID, assetId, DECIMALS),
            abi.encode()
        );
    }

    function _mockNewAssetRegistration(address asset, uint256 tokenId, AssetId assetId) internal {
        // Mock assetToId to return null (asset not yet registered)
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(bytes4(keccak256("assetToId(address,uint256)")), asset, tokenId),
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
            abi.encodeWithSelector(bytes4(keccak256("assetToId(address,uint256)")), asset, tokenId),
            abi.encode(assetId)
        );
    }

    function _mockEscrowDeposit(address asset, uint256 tokenId, uint128 amount) internal {
        vm.mockCall(
            escrow, abi.encodeWithSelector(IPoolEscrow.deposit.selector, SC_1, asset, tokenId, amount), abi.encode()
        );
    }

    function _mockEscrowWithdraw(address asset, uint256 tokenId, uint128 amount) internal {
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, asset, tokenId, TO, amount),
            abi.encode()
        );
        vm.mockCall(
            escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, asset, tokenId, TO, amount), abi.encode()
        );
    }

    function _mockEscrowReserve(address asset, uint256 tokenId, uint128 amount, address reserver, bytes32 reason)
        internal
    {
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.reserve.selector, SC_1, asset, tokenId, amount, reserver, reason),
            abi.encode()
        );
    }

    function _mockEscrowUnreserve(address asset, uint256 tokenId, uint128 amount, address reserver, bytes32 reason)
        internal
    {
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.unreserve.selector, SC_1, asset, tokenId, amount, reserver, reason),
            abi.encode()
        );
    }

    function _mockShareMint(uint128 amount) internal {
        vm.mockCall(
            address(registrar), abi.encodeWithSelector(IRegistrar.mint.selector, share, TO, amount), abi.encode()
        );
    }

    function _mockShareBurn(address from, uint128 amount) internal {
        vm.mockCall(
            address(share),
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, address(spoke), amount),
            abi.encode(true)
        );
        vm.mockCall(
            address(share), abi.encodeWithSelector(IERC20.approve.selector, registrar, amount), abi.encode(true)
        );
        vm.mockCall(
            address(registrar),
            abi.encodeWithSelector(IRegistrar.burn.selector, share, address(spoke), amount),
            abi.encode()
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
        emit ISpoke.File("sender", address(42));
        spoke.file("sender", address(42));
        assertEq(address(spoke.sender()), address(42));

        spoke.file("gateway", address(26));
        assertEq(address(spoke.gateway()), address(26));
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

    function testErrEmptyAmount() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.EmptyAmount.selector);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, 0, 0, 0, REFUND
        );
    }

    function _mockCrossTransferShare(address sender_, bool value) public {
        vm.mockCall(
            address(registrar),
            abi.encodeWithSelector(
                IRegistrar.canBridge.selector, address(share), sender_, REMOTE_CENTRIFUGE_ID, AMOUNT
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
        // The share class does not exist, so the transfer is rejected up front.
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(address(0), address(0))
        );

        vm.prank(ANY);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        spoke.crosschainTransferShares{value: COST}(
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), ANY, ANY, AMOUNT, 0, 0, REFUND
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

    /// @dev The 6-param overload defaults sender, owner, and refund to the caller and extraGasLimit to 0.
    function testCrossChainTransferOwnSharesOverload() public {
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
            REMOTE_CENTRIFUGE_ID, POOL_A, SC_1, RECEIVER.toBytes32(), AMOUNT, 100
        );
    }

    /// @dev A ward (e.g. a compatibility layer) may bridge on behalf of another owner; the
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

contract SpokeTestDeposit is SpokeTest {
    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.deposit(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testDepositERC20() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        vm.mockCall(
            erc20, abi.encodeWithSelector(IERC20.transferFrom.selector, MANAGER, escrow, AMOUNT), abi.encode(true)
        );

        vm.expectCall(erc20, abi.encodeWithSelector(IERC20.transferFrom.selector, MANAGER, escrow, AMOUNT));
        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.Deposit(POOL_A, SC_1, MANAGER, erc20, 0, AMOUNT);
        spoke.deposit(POOL_A, SC_1, erc20, 0, AMOUNT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_ID_20);
        assertEq(deposits, AMOUNT);
    }

    function testDepositERC6909() public {
        _mockEscrowDeposit(erc6909, TOKEN_1, AMOUNT);
        vm.mockCall(
            address(erc6909),
            abi.encodeWithSelector(IERC6909.transferFrom.selector, MANAGER, escrow, TOKEN_1, AMOUNT),
            abi.encode(true)
        );

        vm.expectCall(erc6909, abi.encodeWithSelector(IERC6909.transferFrom.selector, MANAGER, escrow, TOKEN_1, AMOUNT));
        vm.prank(MANAGER);
        spoke.deposit(POOL_A, SC_1, address(erc6909), TOKEN_1, AMOUNT);
    }

    function testErrDepositERC6909TransferFailed() public {
        _mockEscrowDeposit(erc6909, TOKEN_1, AMOUNT);
        vm.mockCall(
            address(erc6909),
            abi.encodeWithSelector(IERC6909.transferFrom.selector, MANAGER, escrow, TOKEN_1, AMOUNT),
            abi.encode(false)
        );

        vm.prank(MANAGER);
        vm.expectRevert(TransferFailed.selector);
        spoke.deposit(POOL_A, SC_1, address(erc6909), TOKEN_1, AMOUNT);
    }
}

contract SpokeTestNoteDeposit is SpokeTest {
    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);
    }

    function testNoteDepositDoesNotPullTokens() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT);
        // No transferFrom mock: any call to it would revert since it is not mocked, so success proves no pull.

        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.NoteDeposit(POOL_A, SC_1, MANAGER, erc20, 0, AMOUNT);
        spoke.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (uint128 deposits,) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_ID_20);
        assertEq(deposits, AMOUNT);
    }

    function testNoteDepositZero() public {
        _mockEscrowDeposit(erc20, 0, 0);

        vm.startPrank(MANAGER);
        spoke.noteDeposit(POOL_A, SC_1, erc20, 0, 0);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
    }
}

contract SpokeTestWithdraw is SpokeTest {
    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
    }

    function testWithdraw() public {
        _mockEscrowWithdraw(erc20, 0, AMOUNT);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.Withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        spoke.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 1);

        (, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_ID_20);
        assertEq(withdrawals, AMOUNT);
    }

    function testWithdrawGatedByEscrow() public {
        // The escrow itself enforces total - reserved >= amount; here we simulate that gating reverting.
        vm.mockCallRevert(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, erc20, 0, TO, AMOUNT),
            abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, erc20, 0, AMOUNT, 0)
        );

        vm.prank(MANAGER);
        vm.expectRevert(abi.encodeWithSelector(IEscrow.InsufficientBalance.selector, erc20, 0, AMOUNT, 0));
        spoke.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
    }
}

contract SpokeTestWithdrawReserved is SpokeTest {
    function _mockEscrowWithdrawReserved(uint128 amount, address reserver, bytes32 reason) internal {
        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.unreserve.selector, SC_1, erc20, 0, amount, reserver, reason),
            abi.encode()
        );
        vm.mockCall(
            escrow, abi.encodeWithSelector(IPoolEscrow.withdraw.selector, SC_1, erc20, 0, TO, amount), abi.encode()
        );
        vm.mockCall(escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, erc20, 0, TO, amount), abi.encode());
    }

    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.withdrawReserved(POOL_A, SC_1, erc20, 0, TO, AMOUNT, RESERVER, RESERVE_REASON);
    }

    function testWithdrawReserved() public {
        _mockEscrowWithdrawReserved(AMOUNT, RESERVER, RESERVE_REASON);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.Withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);
        spoke.withdrawReserved(POOL_A, SC_1, erc20, 0, TO, AMOUNT, RESERVER, RESERVE_REASON);

        // No queueing: the holding decrease was already queued when the funds were reserved.
        (,, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(queuedAssetCounter, 0);
    }
}

contract SpokeTestReserveUnreserve is SpokeTest {
    function testReserveErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.reserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
    }

    function testReserveQueuesWithdrawal() public {
        _mockEscrowReserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        vm.prank(MANAGER);
        spoke.reserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        (, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_ID_20);
        assertEq(withdrawals, AMOUNT);
    }

    function testUnreserveErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);
    }

    function testUnreserveQueuesDeposit() public {
        _mockEscrowUnreserve(erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        vm.prank(MANAGER);
        spoke.unreserve(POOL_A, SC_1, erc20, 0, AMOUNT, MANAGER, RESERVE_REASON);

        (uint128 deposits,) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_ID_20);
        assertEq(deposits, AMOUNT);
    }
}

contract SpokeTestWithdrawShares is SpokeTest {
    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.withdrawShares(POOL_A, SC_1, TO, AMOUNT);
    }

    function testWithdrawShares() public {
        vm.mockCall(escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, share, 0, TO, AMOUNT), abi.encode());

        vm.expectCall(escrow, abi.encodeWithSelector(IEscrow.authTransferTo.selector, share, 0, TO, AMOUNT));
        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.WithdrawShares(POOL_A, SC_1, TO, AMOUNT);
        spoke.withdrawShares(POOL_A, SC_1, TO, AMOUNT);

        // No holding/queue accounting for share withdrawals.
        (uint128 delta, bool isPositive, uint32 queuedAssetCounter,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
        assertEq(queuedAssetCounter, 0);
    }

    function testErrShareTokenDoesNotExist() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareToken.selector, POOL_A, SC_1),
            abi.encode(address(0))
        );
        vm.prank(MANAGER);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        spoke.withdrawShares(POOL_A, SC_1, TO, AMOUNT);
    }
}

contract SpokeTestIssue is SpokeTest {
    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.issue(POOL_A, SC_1, TO, AMOUNT);
    }

    function testIssue() public {
        _mockShareMint(AMOUNT);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.Issue(POOL_A, SC_1, MANAGER, TO, AMOUNT);
        spoke.issue(POOL_A, SC_1, TO, AMOUNT);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, true);
    }

    function testErrShareTokenDoesNotExist() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(address(0), address(0))
        );
        vm.prank(MANAGER);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        spoke.issue(POOL_A, SC_1, TO, AMOUNT);
    }
}

contract SpokeTestRevoke is SpokeTest {
    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.revoke(POOL_A, SC_1, AMOUNT);
    }

    function testRevoke() public {
        _mockShareBurn(MANAGER, AMOUNT);

        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.Revoke(POOL_A, SC_1, MANAGER, MANAGER, AMOUNT);
        spoke.revoke(POOL_A, SC_1, AMOUNT);

        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, AMOUNT);
        assertEq(isPositive, false);
    }

    function testErrShareTokenDoesNotExist() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(address(0), address(0))
        );
        vm.prank(MANAGER);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        spoke.revoke(POOL_A, SC_1, AMOUNT);
    }
}

contract SpokeTestSubmitQueuedAssets is SpokeTest {
    function _mockSendUpdateAssets(uint128 amount, bool isDeposit, bool isSnapshot, uint64 nonce) internal {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                SEND_UPDATE_ASSETS_SELECTOR,
                POOL_A,
                SC_1,
                ASSET_ID_20,
                ISpokeMessageSender.UpdateData({
                    netAmount: amount, isIncrease: isDeposit, isSnapshot: isSnapshot, nonce: nonce
                }),
                EXTRA_GAS,
                REFUND
            ),
            abi.encode()
        );
    }

    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_ID_20, EXTRA_GAS, REFUND);
    }

    function testSubmitQueuedAssets() public {
        _mockSendUpdateAssets(0, !IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.prank(MANAGER);
        spoke.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_ID_20, EXTRA_GAS, REFUND);

        (,,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedAssetsAfterDeposit() public {
        _mockEscrowDeposit(erc20, 0, AMOUNT * 3);
        _mockEscrowWithdraw(erc20, 0, AMOUNT);
        _mockSendUpdateAssets(AMOUNT * 2, IS_DEPOSIT, IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        spoke.noteDeposit(POOL_A, SC_1, erc20, 0, AMOUNT * 3);
        spoke.withdraw(POOL_A, SC_1, erc20, 0, TO, AMOUNT);

        vm.expectEmit();
        emit ISnapshotQueue.SubmitQueuedAssets(
            POOL_A, SC_1, ASSET_ID_20, ISpokeMessageSender.UpdateData(AMOUNT * 2, IS_DEPOSIT, IS_SNAPSHOT, 0)
        );
        spoke.submitQueuedAssets{value: COST}(POOL_A, SC_1, ASSET_ID_20, EXTRA_GAS, REFUND);

        (uint128 deposits, uint128 withdrawals) = snapshotQueue.queuedAssets(POOL_A, SC_1, ASSET_ID_20);
        assertEq(deposits, 0);
        assertEq(withdrawals, 0);
    }
}

contract SpokeTestSubmitQueuedShares is SpokeTest {
    function _mockSendUpdateShares(uint128 delta, bool isPositive, bool isSnapshot, uint64 nonce) internal {
        vm.mockCall(
            address(sender),
            COST,
            abi.encodeWithSelector(
                ISpokeMessageSender.sendUpdateShares.selector,
                POOL_A,
                SC_1,
                ISpokeMessageSender.UpdateData({
                    netAmount: delta, isIncrease: isPositive, isSnapshot: isSnapshot, nonce: nonce
                }),
                EXTRA_GAS,
                REFUND
            ),
            abi.encode()
        );
    }

    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);
    }

    function testSubmitQueuedShares() public {
        _mockSendUpdateShares(0, !IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.prank(MANAGER);
        spoke.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);

        (,,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(nonce, 1);
    }

    function testSubmitQueuedSharesAfterIssue() public {
        _mockShareMint(AMOUNT);
        _mockSendUpdateShares(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0);

        vm.startPrank(MANAGER);
        spoke.issue(POOL_A, SC_1, TO, AMOUNT);

        vm.expectEmit();
        emit ISnapshotQueue.SubmitQueuedShares(
            POOL_A, SC_1, ISpokeMessageSender.UpdateData(AMOUNT, IS_ISSUANCE, IS_SNAPSHOT, 0)
        );
        spoke.submitQueuedShares{value: COST}(POOL_A, SC_1, EXTRA_GAS, REFUND);

        (uint128 delta, bool isPositive,, uint64 nonce) = snapshotQueue.queuedShares(POOL_A, SC_1);
        assertEq(delta, 0);
        assertEq(isPositive, false);
        assertEq(nonce, 1);
    }
}

contract SpokeTestTransferSharesFrom is SpokeTest {
    function testErrNotManager() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.NotManager.selector);
        spoke.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }

    function testTransferSharesFrom() public {
        vm.mockCall(
            address(registrar),
            abi.encodeWithSelector(IRegistrar.authTransferFrom.selector, share, SENDER, FROM, TO, AMOUNT),
            abi.encode()
        );

        vm.prank(MANAGER);
        vm.expectEmit();
        emit ISpoke.TransferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
        spoke.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }

    function testErrShareTokenDoesNotExist() public {
        vm.mockCall(
            address(spokeRegistry),
            abi.encodeWithSelector(ISpokeRegistry.shareTokenAndRegistrar.selector, POOL_A, SC_1),
            abi.encode(address(0), address(0))
        );
        vm.prank(MANAGER);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        spoke.transferSharesFrom(POOL_A, SC_1, SENDER, FROM, TO, AMOUNT);
    }
}

contract SpokeTestAvailableBalanceOf is SpokeTest {
    function testAvailableBalanceOfERC20() public {
        uint128 expectedBalance = 1000;

        vm.mockCall(
            escrow,
            abi.encodeWithSelector(IPoolEscrow.availableBalanceOf.selector, SC_1, erc20, 0),
            abi.encode(expectedBalance)
        );

        uint128 balance = spoke.availableBalanceOf(POOL_A, SC_1, erc20, 0);
        assertEq(balance, expectedBalance);
    }

    function testEscrowLookup() public view {
        assertEq(address(spoke.escrow(POOL_A)), escrow);
    }
}
