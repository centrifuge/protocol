// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";
import {IERC20Metadata} from "../../../../src/misc/interfaces/IERC20.sol";
import {IERC6909MetadataExt} from "../../../../src/misc/interfaces/IERC6909.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {Spoke, ISpoke} from "../../../../src/core/spoke/Spoke.sol";
import {IGateway} from "../../../../src/core/interfaces/IGateway.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {VaultRegistry} from "../../../../src/core/spoke/VaultRegistry.sol";
import {IPoolEscrow} from "../../../../src/core/spoke/interfaces/IPoolEscrow.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {IVault, VaultKind} from "../../../../src/core/spoke/interfaces/IVault.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";
import {ITokenFactory} from "../../../../src/core/spoke/factories/interfaces/ITokenFactory.sol";
import {IVaultFactory} from "../../../../src/core/spoke/factories/interfaces/IVaultFactory.sol";
import {IPoolEscrowFactory} from "../../../../src/core/spoke/factories/interfaces/IPoolEscrowFactory.sol";
import {ISpokeMessageSender, ILocalCentrifugeId} from "../../../../src/core/interfaces/IGatewaySenders.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract SpokeExt is Spoke {
    constructor(ITokenFactory factory, address deployer) Spoke(factory, deployer) {}

    function assetCounter() public view returns (uint64) {
        return _assetCounter;
    }
}

contract VaultRegistryTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;
    uint16 constant REMOTE_CENTRIFUGE_ID = 2;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");
    address immutable REFUND = makeAddr("REFUND");

    ITokenFactory tokenFactory = ITokenFactory(makeAddr("tokenFactory"));
    IPoolEscrowFactory poolEscrowFactory = IPoolEscrowFactory(address(new IsContract()));
    IVaultFactory vaultFactory = IVaultFactory(address(new IsContract()));
    ISpokeMessageSender sender = ISpokeMessageSender(address(new IsContract()));
    IGateway gateway = IGateway(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));
    IPoolEscrow escrow = IPoolEscrow(address(new IsContract()));
    IRequestManager requestManager = IRequestManager(address(new IsContract()));
    IVault vault = IVault(address(new IsContract()));

    address HOOK = makeAddr("hook");
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
    uint64 immutable MAX_AGE = 10_000;
    uint256 constant COST = 123;

    SpokeExt spoke = new SpokeExt(tokenFactory, AUTH);
    VaultRegistry vaultRegistry = new VaultRegistry(AUTH);

    function setUp() public virtual {
        vm.deal(ANY, 1 ether);
        vm.deal(AUTH, 1 ether);
        vm.deal(address(requestManager), 1 ether);

        vm.startPrank(AUTH);
        spoke.file("gateway", address(gateway));
        spoke.file("sender", address(sender));
        spoke.file("poolEscrowFactory", address(poolEscrowFactory));

        vaultRegistry.file("spoke", address(spoke));
        spoke.rely(address(vaultRegistry));

        vm.stopPrank();
        vm.warp(MAX_AGE);

        // Mock gateway calls
        vm.mockCall(address(gateway), abi.encodeWithSelector(IGateway.setUnpaidMode.selector, true), abi.encode());
        vm.mockCall(address(gateway), abi.encodeWithSelector(IGateway.setUnpaidMode.selector, false), abi.encode());

        // Mock sender calls
        vm.mockCall(
            address(sender),
            abi.encodeWithSelector(ILocalCentrifugeId.localCentrifugeId.selector),
            abi.encode(LOCAL_CENTRIFUGE_ID)
        );

        // Mock sendRegisterAsset call
        vm.mockCall(
            address(sender), abi.encodeWithSelector(ISpokeMessageSender.sendRegisterAsset.selector), abi.encode()
        );

        // Mock tokenFactory call
        vm.mockCall(address(tokenFactory), abi.encodeWithSelector(ITokenFactory.newToken.selector), abi.encode(share));

        // Mock poolEscrowFactory call
        vm.mockCall(
            address(poolEscrowFactory),
            abi.encodeWithSelector(IPoolEscrowFactory.newEscrow.selector),
            abi.encode(escrow)
        );

        // Mock share token calls
        vm.mockCall(address(share), abi.encodeWithSignature("file(bytes32,string)", bytes32(0), ""), abi.encode());
        vm.mockCall(address(share), abi.encodeWithSelector(IShareToken.updateVault.selector), abi.encode());

        // Mock vault calls (for tests that don't call _mockVaultFactory)
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL_A));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC_1));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.vaultKind.selector), abi.encode(VaultKind.Async));
    }

    // Utility functions
    function _utilAddPool() internal {
        vm.prank(AUTH);
        spoke.addPool(POOL_A);
    }

    function _utilAddShareClass(address hook) internal {
        vm.prank(AUTH);
        spoke.addShareClass(POOL_A, SC_1, NAME, SYMBOL, DECIMALS, SALT, hook);
    }

    function _utilRegisterAsset(address asset) internal {
        uint256 tokenId = asset == erc6909 ? TOKEN_1 : 0;

        if (asset == erc6909) {
            // ERC6909 mocks
            vm.mockCall(
                asset, abi.encodeWithSelector(IERC6909MetadataExt.decimals.selector, tokenId), abi.encode(DECIMALS)
            );
            vm.mockCall(asset, abi.encodeWithSelector(IERC6909MetadataExt.name.selector, tokenId), abi.encode(NAME));
            vm.mockCall(asset, abi.encodeWithSelector(IERC6909MetadataExt.symbol.selector, tokenId), abi.encode(SYMBOL));
        } else {
            // ERC20 mocks
            vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(DECIMALS));
            vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.name.selector), abi.encode(NAME));
            vm.mockCall(asset, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode(SYMBOL));
        }

        vm.prank(AUTH);
        spoke.registerAsset{value: COST}(REMOTE_CENTRIFUGE_ID, asset, tokenId, REFUND);
    }

    function _mockVaultFactory(address asset, uint256 tokenId) internal {
        address[] memory emptyArray = new address[](0);
        vm.mockCall(
            address(vaultFactory),
            abi.encodeWithSelector(IVaultFactory.newVault.selector, POOL_A, SC_1, asset, tokenId, share, emptyArray),
            abi.encode(vault)
        );

        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL_A));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC_1));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.vaultKind.selector), abi.encode(VaultKind.Async));
    }

    function _utilAddPoolAndShareClass(address hook) internal {
        _utilAddPool();
        _utilAddShareClass(hook);
    }
}

contract VaultRegistryTestDeployVault is VaultRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrShareTokenDoesNotExists() public {
        _utilRegisterAsset(erc6909); // Register asset so we pass the first check

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrUnknownAsset() public {
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrInvalidRequestManager() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockVaultFactory(erc6909, TOKEN_1);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidRequestManager.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testDeployVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockVaultFactory(erc6909, TOKEN_1);

        vm.prank(AUTH);
        spoke.setRequestManager(POOL_A, requestManager);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.DeployVault(POOL_A, SC_1, erc6909, TOKEN_1, vaultFactory, vault, VaultKind.Async);
        IVault returnedVault = vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);

        assertEq(address(returnedVault), address(vault));
        assertEq(vaultRegistry.vaultDetails(vault).assetId.raw(), ASSET_ID_6909_1.raw());
        assertEq(vaultRegistry.vaultDetails(vault).asset, erc6909);
        assertEq(vaultRegistry.vaultDetails(vault).tokenId, TOKEN_1);
        assertEq(vaultRegistry.vaultDetails(vault).isLinked, false);
    }
}

contract VaultRegistryTestRegisterVault is VaultRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault);
    }

    // Successful case tested under VaultRegistryTestDeployVault
}

contract VaultRegistryTestLinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset) internal {
        _mockVaultFactory(asset, asset == erc6909 ? TOKEN_1 : 0);

        vm.prank(AUTH);
        spoke.setRequestManager(POOL_A, requestManager);

        vm.prank(AUTH);
        vaultRegistry.deployVault(POOL_A, SC_1, asset == erc6909 ? ASSET_ID_6909_1 : ASSET_ID_20, vaultFactory);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByShareClassId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.scId.selector), abi.encode(SC_2));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrShareTokenDoesNotExists() public {
        _utilRegisterAsset(erc6909);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyLinkedVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        vm.prank(AUTH);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.AlreadyLinkedVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testLinkVaultERC6909() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.LinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(vaultRegistry.isLinked(vault), true);
        assertEq(address(vaultRegistry.vault(POOL_A, SC_1, ASSET_ID_6909_1, requestManager)), address(vault));
    }

    function testLinkVaultERC20() public {
        _utilRegisterAsset(erc20);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc20);

        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(spoke.setShareTokenVault.selector, POOL_A, SC_1, erc20, vault),
            abi.encode()
        );

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.LinkVault(POOL_A, SC_1, erc20, 0, vault);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }
}

contract VaultRegistryTestUnlinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset) internal {
        _mockVaultFactory(asset, asset == erc6909 ? TOKEN_1 : 0);

        vm.prank(AUTH);
        spoke.setRequestManager(POOL_A, requestManager);

        vm.prank(AUTH);
        vaultRegistry.deployVault(POOL_A, SC_1, asset == erc6909 ? ASSET_ID_6909_1 : ASSET_ID_20, vaultFactory);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByShareClassId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.scId.selector), abi.encode(SC_2));

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.InvalidVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownAsset.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrShareTokenDoesNotExists() public {
        _utilRegisterAsset(erc6909);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyUnlinkedVault() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        vm.prank(AUTH);
        vm.expectRevert(ISpoke.AlreadyUnlinkedVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testUnlinkVaultERC6909() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc6909);

        vm.prank(AUTH);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UnlinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(vaultRegistry.isLinked(vault), false);
        assertEq(address(vaultRegistry.vault(POOL_A, SC_1, ASSET_ID_6909_1, requestManager)), address(0));
    }

    function testUnlinkVaultERC20() public {
        _utilRegisterAsset(erc20);
        _utilAddPoolAndShareClass(NO_HOOK);
        _utilDeployVault(erc20);

        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(spoke.setShareTokenVault.selector, POOL_A, SC_1, erc20, vault),
            abi.encode()
        );

        vm.prank(AUTH);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);

        vm.mockCall(
            address(spoke),
            abi.encodeWithSelector(spoke.setShareTokenVault.selector, POOL_A, SC_1, erc20, address(0)),
            abi.encode()
        );

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpoke.UnlinkVault(POOL_A, SC_1, erc20, 0, vault);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }
}

contract VaultRegistryTestUpdateVault is VaultRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vaultFactory), VaultUpdateKind.DeployAndLink);
    }

    function testDeployAndLinkAndUnlinkAndLink() public {
        _utilRegisterAsset(erc6909);
        _utilAddPoolAndShareClass(NO_HOOK);

        _mockVaultFactory(erc6909, TOKEN_1);

        vm.prank(AUTH);
        spoke.setRequestManager(POOL_A, requestManager);

        vm.prank(AUTH);
        vaultRegistry.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vaultFactory), VaultUpdateKind.DeployAndLink);

        assertEq(vaultRegistry.isLinked(vault), true, "deploy and linked");

        vm.prank(AUTH);
        vaultRegistry.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault), VaultUpdateKind.Unlink);

        assertEq(vaultRegistry.isLinked(vault), false, "unlinked");

        vm.prank(AUTH);
        vaultRegistry.updateVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault), VaultUpdateKind.Link);

        assertEq(vaultRegistry.isLinked(vault), true, "linked again");
    }
}

contract VaultRegistryTestVaultDetails is VaultRegistryTest {
    function testErrUnknownVault() public {
        vm.prank(ANY);
        vm.expectRevert(ISpoke.UnknownVault.selector);
        vaultRegistry.vaultDetails(vault);
    }
}
