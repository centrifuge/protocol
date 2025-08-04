// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "./BaseTest.sol";

import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {MessageLib} from "../../../src/common/libraries/MessageLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";

import {ShareToken} from "../../../src/spoke/ShareToken.sol";
import {VaultDetails} from "../../../src/spoke/interfaces/ISpoke.sol";
import {IVault} from "../../../src/spoke/interfaces/IVaultManager.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

contract SpokeTestHelper is BaseTest {
    PoolId poolId;
    uint8 decimals;
    string tokenName;
    string tokenSymbol;
    ShareClassId scId;
    address assetErc20;
    AssetId assetIdErc20;
    IVault immutable VAULT = IVault(makeAddr("Vault"));

    function setUpPoolAndShare(
        PoolId poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        ShareClassId scId_
    ) public {
        decimals_ = uint8(bound(decimals_, 2, 18));
        vm.assume(bytes(tokenName_).length <= 128);
        vm.assume(bytes(tokenSymbol_).length <= 32);

        poolId = poolId_;
        decimals = decimals_;
        tokenName = tokenName;
        tokenSymbol = tokenSymbol_;
        scId = scId_;

        spoke.addPool(poolId);
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, bytes32(0), address(0));
    }

    function registerAssetErc20() public {
        assetErc20 = address(_newErc20(tokenName, tokenSymbol, decimals));
        assetIdErc20 = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, assetErc20, 0);
    }
}

// TODO: Refactorize and move this to restriction tests
contract SpokeRestrictionTest is BaseTest, SpokeTestHelper {
    using MessageLib for *;
    using UpdateRestrictionMessageLib for *;
    using CastLib for *;

    function testFreezeAndUnfreeze() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IShareToken shareToken = IShareToken(AsyncVault(vault_).share());
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address secondUser = makeAddr("secondUser");

        spoke.updateRestriction(
            poolId,
            scId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize()
        );
        spoke.updateRestriction(
            poolId,
            scId,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(secondUser.toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(
            poolId, scId, UpdateRestrictionMessageLib.UpdateRestrictionFreeze(randomUser.toBytes32()).serialize()
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(
            poolId, scId, UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(randomUser.toBytes32()).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(
            poolId, scId, UpdateRestrictionMessageLib.UpdateRestrictionFreeze(secondUser.toBytes32()).serialize()
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(
            poolId, scId, UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(secondUser.toBytes32()).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));
    }
}

// TODO: refactor and move to vaults
contract SpokeDeployVaultTest is BaseTest, SpokeTestHelper {
    using MessageLib for *;
    using CastLib for *;
    using BytesLib for *;

    function _assertVaultSetup(address vaultAddress, AssetId assetId, address asset, uint256 tokenId, bool isLinked)
        private
        view
    {
        IShareToken token_ = spoke.shareToken(poolId, scId);
        address vault_ = IShareToken(token_).vault(asset);

        assert(spoke.isPoolActive(poolId));

        VaultDetails memory vaultDetails = spoke.vaultDetails(IBaseVault(vaultAddress));
        assertEq(assetId.raw(), vaultDetails.assetId.raw(), "vault assetId mismatch");
        assertEq(asset, vaultDetails.asset, "vault asset mismatch");
        assertEq(tokenId, vaultDetails.tokenId, "vault asset mismatch");
        assertEq(isLinked, vaultDetails.isLinked, "vault isLinked mismatch");

        if (isLinked) {
            assert(spoke.isLinked(IBaseVault(vaultAddress)));

            // check vault state
            assertEq(vaultAddress, vault_, "vault address mismatch");
            AsyncVault vault = AsyncVault(vault_);
            assertEq(address(vault.manager()), address(asyncRequestManager), "investment manager mismatch");
            assertEq(vault.asset(), asset, "asset mismatch");
            assertEq(vault.poolId().raw(), poolId.raw(), "poolId mismatch");
            assertEq(vault.scId().raw(), scId.raw(), "scId mismatch");
            assertEq(address(vault.share()), address(token_), "share class token mismatch");

            assertEq(vault.wards(address(asyncRequestManager)), 1);
            assertEq(vault.wards(address(this)), 0);
            assertEq(asyncRequestManager.wards(vaultAddress), 1);
        } else {
            assert(!spoke.isLinked(IBaseVault(vaultAddress)));

            // Check missing link
            assertEq(vault_, address(0), "Share link to vault requires linkVault");
        }
    }

    function _assertShareSetup() private view {
        IShareToken token_ = spoke.shareToken(poolId, scId);
        ShareToken shareToken = ShareToken(address(token_));

        assertEq(shareToken.wards(address(spoke)), 1);
        assertEq(shareToken.wards(address(this)), 0);

        assertEq(shareToken.name(), tokenName, "share class token name mismatch");
        assertEq(shareToken.symbol(), tokenSymbol, "share class token symbol mismatch");
        assertEq(shareToken.decimals(), decimals, "share class token decimals mismatch");
    }

    function _assertDeployedVault(address vaultAddress, AssetId assetId, address asset, uint256 tokenId, bool isLinked)
        internal
        view
    {
        _assertVaultSetup(vaultAddress, assetId, asset, tokenId, isLinked);
        _assertShareSetup();
    }

    function testDeployVaultWithoutLinkERC20(
        PoolId poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        ShareClassId scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        address asset = address(erc20);

        // Check event except for vault address which cannot be known
        AssetId assetId = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, asset, erc20TokenId);
        IVault vault = spoke.deployVault(poolId, scId, assetId, asyncVaultFactory);

        _assertDeployedVault(address(vault), assetId, asset, erc20TokenId, false);
    }

    function testDeployVaultWithLinkERC20(
        PoolId poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        ShareClassId scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        address asset = address(erc20);

        AssetId assetId = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, asset, erc20TokenId);
        IVault vault = spoke.deployVault(poolId, scId, assetId, asyncVaultFactory);

        spoke.linkVault(poolId, scId, assetId, vault);

        _assertDeployedVault(address(vault), assetId, asset, erc20TokenId, true);
    }
}
