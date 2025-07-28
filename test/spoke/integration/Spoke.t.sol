// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC6909} from "../../misc/mocks/MockERC6909.sol";

import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";

import {PoolId} from "../../../src/common/types/PoolId.sol";
import {AssetId} from "../../../src/common/types/AssetId.sol";
import {IGateway} from "../../../src/common/interfaces/IGateway.sol";
import {MessageLib} from "../../../src/common/libraries/MessageLib.sol";
import {ShareClassId} from "../../../src/common/types/ShareClassId.sol";
import {ITransferHook} from "../../../src/common/interfaces/ITransferHook.sol";

import {ShareToken} from "../../../src/spoke/ShareToken.sol";
import {IVault} from "../../../src/spoke/interfaces/IVaultManager.sol";
import {ISpoke, VaultDetails} from "../../../src/spoke/interfaces/ISpoke.sol";
import {IUpdateContract} from "../../../src/spoke/interfaces/IUpdateContract.sol";

import {IBaseVault} from "../../../src/vaults/interfaces/IBaseVault.sol";
import {AsyncVaultFactory} from "../../../src/vaults/factories/AsyncVaultFactory.sol";

import {IMemberlist} from "../../../src/hooks/interfaces/IMemberlist.sol";
import {UpdateRestrictionMessageLib} from "../../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {MockHook} from "../mocks/MockHook.sol";

import "../BaseTest.sol";

contract SpokeTestHelper is BaseTest {
    PoolId poolId;
    uint8 decimals;
    string tokenName;
    string tokenSymbol;
    ShareClassId scId;
    address assetErc20;
    AssetId assetIdErc20;
    IVault immutable VAULT = IVault(makeAddr("Vault"));

    // helpers
    function hasDuplicates(ShareClassId[4] calldata array) internal pure returns (bool) {
        uint256 length = array.length;
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = i + 1; j < length; j++) {
                if (array[i].raw() == array[j].raw()) {
                    return true;
                }
            }
        }
        return false;
    }

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
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, bytes32(0), address(new MockHook()));
    }

    function registerAssetErc20() public {
        assetErc20 = address(_newErc20(tokenName, tokenSymbol, decimals));
        assetIdErc20 = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, assetErc20, 0);
    }
}

contract SpokeTest is BaseTest, SpokeTestHelper {
    using MessageLib for *;
    using UpdateRestrictionMessageLib for *;
    using CastLib for *;

    function testFile() public {
        address newSender = makeAddr("newSender");
        vm.expectEmit();
        emit ISpoke.File("sender", newSender);
        spoke.file("sender", newSender);
        assertEq(address(spoke.sender()), newSender);

        address newTokenFactory = makeAddr("newTokenFactory");
        vm.expectEmit();
        emit ISpoke.File("tokenFactory", newTokenFactory);
        spoke.file("tokenFactory", newTokenFactory);
        assertEq(address(spoke.tokenFactory()), newTokenFactory);

        address newPoolEscrowFactory = makeAddr("newPoolEscrowFactory");
        vm.expectEmit();
        emit ISpoke.File("poolEscrowFactory", newPoolEscrowFactory);
        spoke.file("poolEscrowFactory", newPoolEscrowFactory);
        assertEq(address(spoke.poolEscrowFactory()), newPoolEscrowFactory);

        address newEscrow = makeAddr("newEscrow");
        vm.expectRevert(ISpoke.FileUnrecognizedParam.selector);
        spoke.file("escrow", newEscrow);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.file("", address(0));
    }

    function testAddPool(PoolId poolId) public {
        spoke.addPool(poolId);

        vm.expectRevert(ISpoke.PoolAlreadyAdded.selector);
        spoke.addPool(poolId);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        spoke.addPool(poolId);
    }

    function testAddShareClass(
        PoolId poolId,
        ShareClassId scId,
        string memory tokenName,
        string memory tokenSymbol,
        bytes32 salt,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());

        vm.expectRevert(ISpoke.InvalidPool.selector);
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);
        spoke.addPool(poolId);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);

        vm.expectRevert(ISpoke.TooFewDecimals.selector);
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, 0, bytes32(0), hook);

        vm.expectRevert(ISpoke.TooManyDecimals.selector);
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, 19, bytes32(0), hook);

        vm.expectRevert(ISpoke.InvalidHook.selector);
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, address(1));

        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);
        IShareToken shareToken = spoke.shareToken(poolId, scId);
        assertEq(tokenName, shareToken.name());
        assertEq(tokenSymbol, shareToken.symbol());
        assertEq(decimals, shareToken.decimals());
        assertEq(hook, shareToken.hook());

        vm.expectRevert(ISpoke.ShareClassAlreadyRegistered.selector);
        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);
    }

    function testAddMultipleSharesWorks(
        PoolId poolId,
        ShareClassId[4] calldata scIds,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(!hasDuplicates(scIds));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        spoke.addPool(poolId);

        address hook = address(new MockHook());

        for (uint256 i = 0; i < scIds.length; i++) {
            spoke.addShareClass(poolId, scIds[i], tokenName, tokenSymbol, decimals, bytes32(i), hook);
            IShareToken shareToken = spoke.shareToken(poolId, scIds[i]);
            assertEq(tokenName, shareToken.name());
            assertEq(tokenSymbol, shareToken.symbol());
            assertEq(decimals, shareToken.decimals());
        }
    }

    function testTransferSharesToCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        bytes32 centChainAddress = makeAddr("centChainAddress").toBytes32();
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        // fund this account with amount
        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );

        spoke.executeTransferShares(vault.poolId(), vault.scId(), address(this).toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount); // Verify the address(this) has the expected amount

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(
                address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max
            ).serialize()
        );

        // fails for invalid share class token
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.crosschainTransferShares{value: DEFAULT_GAS}(
            OTHER_CHAIN_ID, PoolId.wrap(poolId.raw() + 1), scId, centChainAddress, amount, 0
        );

        // send the transfer from EVM -> Cent Chain
        spoke.crosschainTransferShares{value: DEFAULT_GAS}(OTHER_CHAIN_ID, poolId, scId, centChainAddress, amount, 0);
        assertEq(shareToken.balanceOf(address(this)), 0);

        // Finally, verify the connector called `adapter.send`
        bytes memory message = MessageLib.InitiateTransferShares(
            poolId.raw(), scId.raw(), OTHER_CHAIN_ID, centChainAddress, amount, 0
        ).serialize();
        assertEq(adapter1.sent(message), 1);
    }

    // TODO: Refactorize and move this to restriction tests
    function testCrossChainTransferSharesToEVM(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );
        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with amount
        spoke.executeTransferShares(vault.poolId(), vault.scId(), address(this).toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(
                address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max
            ).serialize()
        );

        // Transfer amount from this address to destinationAddress
        spoke.crosschainTransferShares{value: DEFAULT_GAS}(
            OTHER_CHAIN_ID, vault.poolId(), vault.scId(), destinationAddress.toBytes32(), amount, 0
        );
        assertEq(shareToken.balanceOf(address(this)), 0);
    }

    // TODO: Refactorize and move this to restriction tests
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

    // TODO: refacorize and move this to restriction tests
    function testSpokeCannotTransferSharesOnAccountRestrictions(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));
        shareToken.approve(address(spoke), amount);

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );
        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );

        assertTrue(shareToken.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with amount
        spoke.executeTransferShares(vault.poolId(), vault.scId(), address(this).toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        // fails for invalid share class token
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        spoke.updateRestriction(
            poolId, scId, UpdateRestrictionMessageLib.UpdateRestrictionFreeze(address(this).toBytes32()).serialize()
        );
        assertFalse(shareToken.checkTransferRestriction(address(this), destinationAddress, 0));

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            UpdateRestrictionMessageLib.UpdateRestrictionMember(
                address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max
            ).serialize()
        );

        assertEq(shareToken.balanceOf(address(this)), amount);

        spoke.updateRestriction(
            poolId, scId, UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze(address(this).toBytes32()).serialize()
        );
        spoke.crosschainTransferShares{value: DEFAULT_GAS}(
            OTHER_CHAIN_ID, poolId, scId, destinationAddress.toBytes32(), amount, 0
        );
        assertEq(shareToken.balanceOf(address(poolEscrowFactory.escrow(poolId))), 0);
    }
}

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
            assertEq(
                asyncRequestManager.wards(vaultAddress), 0, "Vault auth on asyncRequestManager set up in linkVault"
            );
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
