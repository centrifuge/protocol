// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";
import {IRegistrar} from "../../../../src/core/spoke/interfaces/IRegistrar.sol";
import {IVaultFactory} from "../../../../src/core/spoke/factories/interfaces/IVaultFactory.sol";
import {ISpokeRequestManager} from "../../../../src/core/spoke/interfaces/ISpokeRequestManager.sol";
import {SpokeRegistry, ISpokeRegistry, VaultDetails} from "../../../../src/core/spoke/SpokeRegistry.sol";

import "forge-std/Test.sol";

// Need it to overpass a mockCall issue: https://github.com/foundry-rs/foundry/issues/10703
contract IsContract {}

contract VaultRegistryTest is Test {
    uint16 constant LOCAL_CENTRIFUGE_ID = 1;

    address immutable AUTH = makeAddr("AUTH");
    address immutable ANY = makeAddr("ANY");

    IVaultFactory vaultFactory = IVaultFactory(address(new IsContract()));
    address share = address(new IsContract());
    IRegistrar registrar = IRegistrar(address(new IsContract()));
    ISpokeRequestManager requestManager = ISpokeRequestManager(address(new IsContract()));
    address vault = address(new IsContract());

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

    function _utilAddPool() internal {
        vm.prank(AUTH);
        spokeRegistry.addPool(POOL_A);
    }

    function _utilAddShareClass() internal {
        vm.prank(AUTH);
        spokeRegistry.addShareClass(POOL_A, SC_1, share, registrar);
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
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, "");
    }

    function testErrShareTokenDoesNotExist() public {
        _utilRegisterERC6909();
        _utilAddPool();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, "");
    }

    function testErrUnknownAssetMismatch() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();

        // The passed (asset, tokenId) must match what assetId resolves to.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc20, 0, vaultFactory, vault, "");
    }

    function testErrUnknownAssetUnregistered() public {
        _utilAddPoolAndShareClass();

        // The assetId is not registered, so it resolves to a zeroed key and is rejected up front.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, "");
    }

    function testErrReregisterLinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();

        vm.startPrank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, "");
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));

        // Any previously-registered vault address is permanently rejected, linked or not.
        vm.expectRevert(ISpokeRegistry.AlreadyRegisteredVault.selector);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, "");
        vm.stopPrank();
    }

    /// @dev The opaque factory `payload` is carried on the canonical DeployVault event verbatim, so offchain
    ///      consumers can bootstrap from it. Asserted with a non-empty value: an empty payload would pass
    ///      even if the field were dropped from the event.
    function testRegisterVaultEmitsDeployVaultWithPayload() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();

        bytes memory payload = hex"deadbeefc0ffee";

        vm.expectEmit();
        emit ISpokeRegistry.DeployVault(POOL_A, SC_1, erc6909, TOKEN_1, vaultFactory, vault, payload);

        vm.prank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, payload);

        // The payload is not retained in storage; the event is the only record of it.
        VaultDetails memory details = spokeRegistry.vaultDetails(vault);
        assertEq(details.poolId.raw(), POOL_A.raw());
        assertEq(details.scId.raw(), SC_1.raw());
        assertEq(details.asset, erc6909);
        assertEq(details.tokenId, TOKEN_1);
    }

    /// @dev A pool-B manager supplying an unlinked pool-A vault address must be rejected.
    function testErrReregisterUnlinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();

        vm.startPrank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, "");
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));

        vm.expectRevert(ISpokeRegistry.AlreadyRegisteredVault.selector);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault, "");
        vm.stopPrank();
    }

    /// @dev A factory that returns a not-yet-deployed address (preemptive front-run) is rejected.
    function testErrVaultNotDeployed() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();

        address noCode = makeAddr("noCode");
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.NotAContract.selector);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, noCode, "");
    }
}

contract VaultRegistryTestLinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset, uint256 tokenId, AssetId assetId) internal {
        vm.prank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, assetId, asset, tokenId, vaultFactory, vault, "");
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testErrInvalidVaultByPoolId() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        // The vault was registered under POOL_A, so linking it under another pool is rejected.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidVault.selector);
        spokeRegistry.linkVault(POOL_B, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testErrInvalidVaultByShareClassId() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidVault.selector);
        spokeRegistry.linkVault(POOL_A, SC_2, ASSET_ID_6909_1, address(vault));
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testErrUnknownVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownVault.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testErrAssetIdMismatch() public {
        _utilRegisterERC6909();
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        // Linking under a different assetId than the vault was registered with is rejected.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, address(vault));
    }

    function testErrAlreadyLinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.AlreadyLinkedVault.selector);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testLinkVaultERC6909() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.LinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));

        assertEq(spokeRegistry.isLinked(address(vault)), true);
    }

    function testLinkVaultERC20() public {
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc20, 0, ASSET_ID_20);

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.LinkVault(POOL_A, SC_1, erc20, 0, vault);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, address(vault));
    }

    function testLinkSecondVaultSameTuple() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        // Register a second, distinct vault for the same (poolId, scId, assetId).
        address vault2 = address(new IsContract());
        vm.prank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_6909_1, erc6909, TOKEN_1, vaultFactory, vault2, "");

        // The registry is declarative (no tuple -> vault reverse lookup), so multiple vaults may be linked
        // to the same tuple; each carries its own `isLinked` bit.
        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault2));

        assertEq(spokeRegistry.isLinked(address(vault)), true);
        assertEq(spokeRegistry.isLinked(address(vault2)), true);
    }

    /// @dev Symmetric ERC20 case of the above: for tokenId == 0 the share token's ERC-7575 pointer is
    ///      maintained, so each link aims it at the just-linked vault (last-writer-wins).
    function testLinkSecondVaultSameTupleERC20() public {
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc20, 0, ASSET_ID_20);

        address vault2 = address(new IsContract());
        vm.prank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, ASSET_ID_20, erc20, 0, vaultFactory, vault2, "");

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, address(vault));

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, address(vault2));

        assertEq(spokeRegistry.isLinked(address(vault)), true);
        assertEq(spokeRegistry.isLinked(address(vault2)), true);
    }
}

contract VaultRegistryTestUnlinkVault is VaultRegistryTest {
    function _utilDeployVault(address asset, uint256 tokenId, AssetId assetId) internal {
        vm.prank(AUTH);
        spokeRegistry.registerVault(POOL_A, SC_1, assetId, asset, tokenId, vaultFactory, vault, "");
    }

    function testErrNotAuthorized() public {
        vm.prank(ANY);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testErrInvalidVaultByPoolId() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));

        // The vault was registered and linked under POOL_A, so unlinking it from another pool is rejected.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.InvalidVault.selector);
        spokeRegistry.unlinkVault(POOL_B, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testErrUnknownAsset() public {
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testErrAssetIdMismatch() public {
        _utilRegisterERC6909();
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);
        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, vault);

        // Unlinking under a different assetId than the vault was registered with is rejected.
        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.UnknownAsset.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_20, vault);
    }

    function testErrAlreadyUnlinkedVault() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        vm.expectRevert(ISpokeRegistry.AlreadyUnlinkedVault.selector);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));
    }

    function testUnlinkVaultERC6909() public {
        _utilRegisterERC6909();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc6909, TOKEN_1, ASSET_ID_6909_1);

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UnlinkVault(POOL_A, SC_1, erc6909, TOKEN_1, vault);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_6909_1, address(vault));

        assertEq(spokeRegistry.isLinked(address(vault)), false);
    }

    function testUnlinkVaultERC20() public {
        _utilRegisterERC20();
        _utilAddPoolAndShareClass();
        _utilSetRequestManager();
        _utilDeployVault(erc20, 0, ASSET_ID_20);

        vm.prank(AUTH);
        spokeRegistry.linkVault(POOL_A, SC_1, ASSET_ID_20, address(vault));

        vm.prank(AUTH);
        vm.expectEmit();
        emit ISpokeRegistry.UnlinkVault(POOL_A, SC_1, erc20, 0, vault);
        spokeRegistry.unlinkVault(POOL_A, SC_1, ASSET_ID_20, address(vault));
    }
}

contract VaultRegistryTestVaultDetails is VaultRegistryTest {
    function testUnknownVaultReturnsZero() public view {
        assertFalse(spokeRegistry.isVaultRegistered(address(vault)));
        assertEq(spokeRegistry.vaultDetails(address(vault)).asset, address(0));
    }
}
