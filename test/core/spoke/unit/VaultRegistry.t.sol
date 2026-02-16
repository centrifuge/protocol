// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../../../src/core/types/AssetId.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {IVault, VaultKind} from "../../../../src/core/spoke/interfaces/IVault.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {VaultUpdateKind} from "../../../../src/core/messaging/libraries/MessageLib.sol";
import {SpokeRegistry, ISpokeRegistry} from "../../../../src/core/spoke/SpokeRegistry.sol";
import {VaultRegistry, IVaultRegistry} from "../../../../src/core/spoke/VaultRegistry.sol";
import {IVaultFactory} from "../../../../src/core/spoke/factories/interfaces/IVaultFactory.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract VaultRegistryTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");

    IVaultFactory vaultFactory = IVaultFactory(address(new IsContract()));
    IShareToken share = IShareToken(address(new IsContract()));
    IRequestManager requestManager = IRequestManager(address(new IsContract()));
    IVault vault = IVault(address(new IsContract()));

    address NO_HOOK = address(0);

    PoolId constant POOL_A = PoolId.wrap(1);
    PoolId constant POOL_B = PoolId.wrap(2);
    ShareClassId constant SC_1 = ShareClassId.wrap(bytes16("sc1"));
    ShareClassId constant SC_2 = ShareClassId.wrap(bytes16("sc2"));

    AssetId ASSET_ID_20;
    AssetId ASSET_ID_6909_1;
    address erc20 = address(new IsContract());
    address erc6909 = address(new IsContract());
    uint256 constant TOKEN_1 = 23;

    uint8 constant DECIMALS = 18;
    string constant NAME = "name";
    string constant SYMBOL = "symbol";

    SpokeRegistry spokeRegistry = new SpokeRegistry(AUTH);
    VaultRegistry vaultRegistry = new VaultRegistry(AUTH);

    function setUp() public virtual {
        vm.startPrank(AUTH);
        vaultRegistry.file("spokeRegistry", address(spokeRegistry));
        spokeRegistry.rely(address(vaultRegistry));
        vm.stopPrank();

        // Mock share token calls
        vm.mockCall(address(share), abi.encodeWithSelector(IShareToken.updateVault.selector), abi.encode());

        // Mock vault calls
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL_A));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC_1));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.vaultKind.selector), abi.encode(VaultKind.Async));
    }

    function _utilAddPool() internal {
        vm.prank(AUTH);
        spokeRegistry.addPool(POOL_A);
    }

    function _utilAddShareClass() internal {
        vm.prank(AUTH);
        spokeRegistry.addShareClass(POOL_A, SC_1, share);
    }

    function _utilRegisterAsset(address asset, uint256 tokenId) internal returns (AssetId assetId) {
        vm.prank(AUTH);
        assetId = spokeRegistry.createAssetId(LOCAL_CENTRIFUGE_ID, asset, tokenId);
    }

    function _utilRegisterERC20() internal {
        ASSET_ID_20 = _utilRegisterAsset(erc20, 0);
    }

    function _utilRegisterERC6909() internal {
        ASSET_ID_6909_1 = _utilRegisterAsset(erc6909, TOKEN_1);
    }

    function _mockVaultFactory(address asset, uint256 tokenId) internal {
        vm.mockCall(
            address(vaultFactory),
            abi.encodeWithSelector(IVaultFactory.newVault.selector, POOL_A, SC_1, asset, tokenId, share),
            abi.encode(vault)
        );

        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL_A));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC_1));
        vm.mockCall(address(vault), abi.encodeWithSelector(IVault.vaultKind.selector), abi.encode(VaultKind.Async));
    }

    function _utilAddPoolAndShareClass() internal {
        _utilAddPool();
        _utilAddShareClass();
    }
}

contract VaultRegistryTestDeployVault is VaultRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrShareTokenDoesNotExists() public {
        _utilRegisterERC6909();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrUnknownAsset() public {
        _utilAddPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testErrInvalidRequestManager() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        _mockVaultFactory(erc6909, TOKEN_1);

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.InvalidRequestManager.selector);
        vaultRegistry.deployVault(POOL_A, SC_1, ASSET_ID_6909_1, vaultFactory);
    }

    function testDeployVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        _mockVaultFactory(erc6909, TOKEN_1);

        vm.prank(AUTH);
        spokeRegistry.setRequestManager(POOL_A, requestManager);

        vm.prank(AUTH);
        vm.expectEmit();
        emit IVaultRegistry.DeployVault(POOL_A, SC_1, erc6909, TOKEN_1, vaultFactory, vault, VaultKind.Async);
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
}

contract VaultRegistryTestLinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset, uint256 tokenId, AssetId assetId) internal {
        _mockVaultFactory(asset, tokenId);

        vm.prank(AUTH);
        spokeRegistry.setRequestManager(POOL_A, requestManager);

        vm.prank(AUTH);
        vaultRegistry.deployVault(POOL_A, SC_1, assetId, vaultFactory);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.InvalidVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByShareClassId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.scId.selector), abi.encode(SC_2));

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.InvalidVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.UnknownVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyLinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.AlreadyLinkedVault.selector);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testLinkVaultERC6909() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vm.expectEmit();
        emit IVaultRegistry.LinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(vaultRegistry.isLinked(vault), true);
        assertEq(address(vaultRegistry.vault(POOL_A, SC_1, ASSET_ID_6909_1, requestManager)), address(vault));
    }

    function testLinkVaultERC20() public {
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilDeployVault(erc20, 0, ASSET_ID_20);

        vm.prank(AUTH);
        vm.expectEmit();
        emit IVaultRegistry.LinkVault(POOL_A, SC_1, erc20, 0, vault);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }
}

contract VaultRegistryTestUnlinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset, uint256 tokenId, AssetId assetId) internal {
        _mockVaultFactory(asset, tokenId);

        vm.prank(AUTH);
        spokeRegistry.setRequestManager(POOL_A, requestManager);

        vm.prank(AUTH);
        vaultRegistry.deployVault(POOL_A, SC_1, assetId, vaultFactory);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.InvalidVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.UnknownVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyUnlinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.AlreadyUnlinkedVault.selector);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testUnlinkVaultERC6909() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectEmit();
        emit IVaultRegistry.UnlinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        vaultRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(vaultRegistry.isLinked(vault), false);
        assertEq(address(vaultRegistry.vault(POOL_A, SC_1, ASSET_ID_6909_1, requestManager)), address(0));
    }

    function testUnlinkVaultERC20() public {
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilDeployVault(erc20, 0, ASSET_ID_20);

        vm.prank(AUTH);
        vaultRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);

        vm.prank(AUTH);
        vm.expectEmit();
        emit IVaultRegistry.UnlinkVault(POOL_A, SC_1, erc20, 0, vault);
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
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        _mockVaultFactory(erc6909, TOKEN_1);

        vm.prank(AUTH);
        spokeRegistry.setRequestManager(POOL_A, requestManager);

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
        vm.expectRevert(IVaultRegistry.UnknownVault.selector);
        vaultRegistry.vaultDetails(vault);
    }
}

contract VaultRegistryTestFile is VaultRegistryTest {
    function testFileSpokeRegistry() public {
        ISpokeRegistry newSpokeRegistry = ISpokeRegistry(makeAddr("NewSpokeRegistry"));

        vm.expectEmit(true, true, true, true);
        emit IVaultRegistry.File("spokeRegistry", address(newSpokeRegistry));

        vm.prank(AUTH);
        vaultRegistry.file("spokeRegistry", address(newSpokeRegistry));

        assertEq(address(vaultRegistry.spokeRegistry()), address(newSpokeRegistry));
    }

    function testFileUnrecognizedParam() public {
        vm.prank(AUTH);
        vm.expectRevert(IVaultRegistry.FileUnrecognizedParam.selector);
        vaultRegistry.file("unknown", address(0));
    }

    function testFileNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vaultRegistry.file("spokeRegistry", address(0));
    }
}
