// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {SpokeV3_1_0} from "../../../../src/core/spoke/legacy/SpokeV3_1_0.sol";
import {IShareToken} from "../../../../src/core/spoke/interfaces/IShareToken.sol";
import {IVault, VaultKind} from "../../../../src/core/spoke/interfaces/IVault.sol";
import {IRequestManager} from "../../../../src/core/interfaces/IRequestManager.sol";
import {SpokeRegistry, ISpokeRegistry} from "../../../../src/core/spoke/SpokeRegistry.sol";
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
    SpokeV3_1_0 spokeV3_1_0;

    function setUp() public virtual {
        spokeV3_1_0 = new SpokeV3_1_0(AUTH);
        vm.prank(AUTH);
        spokeV3_1_0.file("spokeRegistry", address(spokeRegistry));
        vm.prank(AUTH);
        spokeRegistry.rely(address(spokeV3_1_0));

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

    function _utilSetRequestManager() internal {
        vm.prank(AUTH);
        spokeRegistry.setRequestManager(POOL_A, requestManager);
    }

    function _utilAddPoolAndShareClass() internal {
        _utilAddPool();
        _utilAddShareClass();
    }
}

contract VaultRegistryTestRegisterVault is VaultRegistryTest {
    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault);
    }
}

contract VaultRegistryTestLinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset, uint256 tokenId, AssetId assetId) internal {
        vm.prank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, assetId, asset, tokenId, vaultFactory, vault);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidVault.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByShareClassId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.scId.selector), abi.encode(SC_2));

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidVault.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownVault.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyLinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.AlreadyLinkedVault.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testLinkVaultERC6909() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.LinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(spokeV3_1_0.isLinked(vault), true);
        assertEq(address(spokeV3_1_0.vault(POOL_A, SC_1, ASSET_ID_6909_1, requestManager)), address(vault));
    }

    function testLinkVaultERC20() public {
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc20, 0, ASSET_ID_20);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.LinkVault(POOL_A, SC_1, erc20, 0, vault);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }
}

contract VaultRegistryTestUnlinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset, uint256 tokenId, AssetId assetId) internal {
        vm.prank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, assetId, asset, tokenId, vaultFactory, vault);
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrInvalidVaultByPoolId() public {
        vm.mockCall(address(vault), abi.encodeWithSelector(vault.poolId.selector), abi.encode(POOL_B));

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidVault.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrUnknownVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownVault.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testErrAlreadyUnlinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.AlreadyUnlinkedVault.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);
    }

    function testUnlinkVaultERC6909() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UnlinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        assertEq(spokeV3_1_0.isLinked(vault), false);
        assertEq(address(spokeV3_1_0.vault(POOL_A, SC_1, ASSET_ID_6909_1, requestManager)), address(0));
    }

    function testUnlinkVaultERC20() public {
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc20, 0, ASSET_ID_20);

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, vault);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UnlinkVault(POOL_A, SC_1, erc20, 0, vault);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }
}

contract VaultRegistryTestVaultDetails is VaultRegistryTest {
    function testErrUnknownVault() public {
        vm.prank(ANY);
        vm.expectRevert(ISpokeRegistry.UnknownVault.selector);
        spokeV3_1_0.vaultDetails(vault);
    }
}
