// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "../../../src/misc/ERC20.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../src/core/types/AssetId.sol";
import {ShareToken} from "../../../src/core/spoke/ShareToken.sol";
import {IVault} from "../../../src/core/spoke/interfaces/IVault.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IShareToken} from "../../../src/core/spoke/interfaces/IShareToken.sol";
import {VaultDetails} from "../../../src/core/spoke/interfaces/IVaultRegistry.sol";

import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {AsyncVault} from "../../../src/vaults/AsyncVault.sol";
import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";

import {CentrifugeIntegrationTest} from "../Integration.t.sol";

contract SpokeRestrictionTest is CentrifugeIntegrationTest {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    PoolId POOL_A;
    ShareClassId SC_1;

    address immutable randomUser = makeAddr("randomUser");
    address immutable secondUser = makeAddr("secondUser");

    function setUp() public override {
        super.setUp();
        // address(this) is FM
        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, address(this), USD_ID);

        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);
        hub.addShareClass(POOL_A, "TestShare", "TST", bytes32(bytes8(POOL_A.raw())));

        // Push pool and share class to spoke
        hub.notifyPool{value: 0}(POOL_A, LOCAL_CENTRIFUGE_ID, address(this));
        hub.notifyShareClass{value: 0}(
            POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, bytes32(bytes20(address(fullRestrictionsHook))), address(this)
        );
    }

    /// forge-config: default.isolate = true
    function testFreezeAndUnfreeze() public {
        IShareToken shareToken = spoke.shareToken(POOL_A, SC_1);
        uint64 validUntil = uint64(block.timestamp + 7 days);

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize(),
            0,
            address(this)
        );
        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionMember(secondUser.toBytes32(), validUntil).serialize(),
            0,
            address(this)
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze(randomUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(randomUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze(secondUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        hub.updateRestriction{value: 0}(
            POOL_A,
            SC_1,
            LOCAL_CENTRIFUGE_ID,
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(secondUser.toBytes32()).serialize(),
            0,
            address(this)
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));
    }
}

contract SpokeDeployVaultTest is CentrifugeIntegrationTest {
    using CastLib for *;

    PoolId POOL_A;
    ShareClassId SC_1;
    AssetId assetId;
    ERC20 asset;
    uint8 shareDecimals;
    string tokenName;
    string tokenSymbol;

    function setUp() public override {
        super.setUp();
        // address(this) is FM
        POOL_A = hubRegistry.poolId(LOCAL_CENTRIFUGE_ID, 1);
        vm.prank(address(opsGuardian.opsSafe()));
        opsGuardian.createPool(POOL_A, address(this), USD_ID);
    }

    function _setUpPoolAndShare() internal {
        // Share token decimals are determined by the pool currency (USD = 18 decimals in deployment)
        shareDecimals = 18;
        tokenName = "TestToken";
        tokenSymbol = "TT";

        SC_1 = shareClassManager.previewNextShareClassId(POOL_A);
        hub.addShareClass(POOL_A, tokenName, tokenSymbol, bytes32(bytes8(POOL_A.raw())));

        hub.notifyPool{value: 0}(POOL_A, LOCAL_CENTRIFUGE_ID, address(this));
        hub.notifyShareClass{value: 0}(POOL_A, SC_1, LOCAL_CENTRIFUGE_ID, bytes32(0), address(this));
    }

    function _registerErc20Asset(uint8 decimals_) internal {
        asset = new ERC20(decimals_);
        asset.file("name", tokenName);
        asset.file("symbol", tokenSymbol);

        // Same-chain short-circuit: also registers the assetId on the hub
        assetId = spoke.registerAsset{value: 0}(LOCAL_CENTRIFUGE_ID, address(asset), 0, address(this));
    }

    function _assertVaultSetup(address vaultAddress, bool isLinked) internal view {
        IShareToken token_ = spoke.shareToken(POOL_A, SC_1);
        address linkedVault = IShareToken(token_).vault(address(asset));

        assertTrue(spoke.isPoolActive(POOL_A));

        VaultDetails memory vaultDetails = vaultRegistry.vaultDetails(IBaseVault(vaultAddress));
        assertEq(assetId.raw(), vaultDetails.assetId.raw(), "vault assetId mismatch");
        assertEq(address(asset), vaultDetails.asset, "vault asset mismatch");
        assertEq(uint256(0), vaultDetails.tokenId, "vault tokenId mismatch");
        assertEq(isLinked, vaultDetails.isLinked, "vault isLinked mismatch");

        if (isLinked) {
            assertTrue(vaultRegistry.isLinked(IBaseVault(vaultAddress)));

            assertEq(vaultAddress, linkedVault, "vault address mismatch");
            AsyncVault vault = AsyncVault(vaultAddress);
            assertEq(vault.asset(), address(asset), "asset mismatch");
            assertEq(vault.poolId().raw(), POOL_A.raw(), "poolId mismatch");
            assertEq(vault.scId().raw(), SC_1.raw(), "scId mismatch");
            assertEq(address(vault.share()), address(token_), "share class token mismatch");

            assertEq(vault.wards(address(asyncRequestManager)), 1);
            assertEq(vault.wards(address(this)), 0);
            assertEq(asyncRequestManager.wards(vaultAddress), 1);
        } else {
            assertFalse(vaultRegistry.isLinked(IBaseVault(vaultAddress)));
            assertEq(linkedVault, address(0), "Share link to vault requires linkVault");
        }
    }

    function _assertShareSetup() internal view {
        ShareToken shareToken = ShareToken(address(spoke.shareToken(POOL_A, SC_1)));

        assertEq(shareToken.wards(address(spoke)), 1);
        assertEq(shareToken.wards(address(this)), 0);

        assertEq(shareToken.name(), tokenName, "share class token name mismatch");
        assertEq(shareToken.symbol(), tokenSymbol, "share class token symbol mismatch");
        assertEq(shareToken.decimals(), shareDecimals, "share class token decimals mismatch");
    }

    /// forge-config: default.isolate = true
    function testDeployVaultWithoutLinkERC20(uint8 assetDecimals_) public {
        assetDecimals_ = uint8(bound(assetDecimals_, 2, 18));
        _setUpPoolAndShare();
        _registerErc20Asset(assetDecimals_);

        vm.prank(address(messageProcessor));
        spoke.setRequestManager(POOL_A, asyncRequestManager);

        vm.prank(address(messageProcessor));
        IVault vault = vaultRegistry.deployVault(POOL_A, SC_1, assetId, asyncVaultFactory);

        _assertVaultSetup(address(vault), false);
        _assertShareSetup();
    }

    /// forge-config: default.isolate = true
    function testDeployVaultWithLinkERC20(uint8 assetDecimals_) public {
        assetDecimals_ = uint8(bound(assetDecimals_, 2, 18));
        _setUpPoolAndShare();
        _registerErc20Asset(assetDecimals_);

        vm.prank(address(messageProcessor));
        spoke.setRequestManager(POOL_A, asyncRequestManager);

        vm.prank(address(messageProcessor));
        IVault vault = vaultRegistry.deployVault(POOL_A, SC_1, assetId, asyncVaultFactory);

        vm.prank(address(messageProcessor));
        vaultRegistry.linkVault(POOL_A, SC_1, assetId, vault);

        _assertVaultSetup(address(vault), true);
        _assertShareSetup();
    }
}
