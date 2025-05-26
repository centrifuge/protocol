// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";
import {MockHook} from "test/spoke/mocks/MockHook.sol";
import "test/spoke/BaseTest.sol";

import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {D18} from "src/misc/types/D18.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId} from "src/common/types/AssetId.sol";

import {ISpoke, VaultDetails} from "src/spoke/interfaces/ISpoke.sol";
import {IBaseVault} from "src/spoke/interfaces/IBaseVault.sol";
import {IUpdateContract} from "src/spoke/interfaces/IUpdateContract.sol";
import {IHook} from "src/common/interfaces/IHook.sol";

import {IMemberlist} from "src/hooks/interfaces/IMemberlist.sol";

contract SpokeTestHelper is BaseTest {
    PoolId poolId;
    uint8 decimals;
    string tokenName;
    string tokenSymbol;
    ShareClassId scId;
    address assetErc20;
    AssetId assetIdErc20;

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
    using CastLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(vaultRouter) && nonWard != address(this)
                && nonWard != address(messageProcessor) && nonWard != address(messageDispatcher)
                && nonWard != address(gateway)
        );

        // redeploying within test to increase coverage
        new Spoke(tokenFactory, address(this));
        spoke.file("vaultFactory", address(asyncVaultFactory), true);

        // values set correctly
        assertEq(address(messageDispatcher.spoke()), address(spoke));
        assertEq(address(asyncRequestManager.spoke()), address(spoke));
        assertEq(address(syncRequestManager.spoke()), address(spoke));

        assertEq(address(spoke.poolEscrowFactory()), address(poolEscrowFactory));
        assertEq(address(spoke.tokenFactory()), address(tokenFactory));
        assertEq(address(spoke.sender()), address(messageDispatcher));

        // permissions set correctly
        assertEq(spoke.wards(address(root)), 1);
        assertEq(spoke.wards(address(gateway)), 1);
        assertEq(spoke.wards(address(vaultRouter)), 1);
        assertEq(spoke.wards(nonWard), 0);
    }

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

        IVaultFactory newVaultFactory = IVaultFactory(makeAddr("newVaultFactory"));
        assertEq(spoke.vaultFactory(newVaultFactory), false);
        spoke.file("vaultFactory", address(newVaultFactory), true);
        assertEq(spoke.vaultFactory(newVaultFactory), true);
        assertEq(spoke.vaultFactory(asyncVaultFactory), true);

        vm.expectEmit();
        emit ISpoke.File("vaultFactory", address(newVaultFactory), false);
        spoke.file("vaultFactory", address(newVaultFactory), false);
        assertEq(spoke.vaultFactory(newVaultFactory), false);

        address newEscrow = makeAddr("newEscrow");
        vm.expectRevert(ISpoke.FileUnrecognizedParam.selector);
        spoke.file("escrow", newEscrow);

        vm.expectRevert(ISpoke.FileUnrecognizedParam.selector);
        spoke.file("escrow", newEscrow, true);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.file("", address(0));

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.file("", address(0), true);
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
            MessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );

        spoke.executeTransferShares(vault.poolId(), vault.scId(), address(this).toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount); // Verify the address(this) has the expected amount

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            MessageLib.UpdateRestrictionMember(address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max).serialize(
            )
        );

        // fails for invalid share class token
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.transferShares{value: DEFAULT_GAS}(
            OTHER_CHAIN_ID, PoolId.wrap(poolId.raw() + 1), scId, centChainAddress, amount
        );

        // send the transfer from EVM -> Cent Chain
        spoke.transferShares{value: DEFAULT_GAS}(OTHER_CHAIN_ID, poolId, scId, centChainAddress, amount);
        assertEq(shareToken.balanceOf(address(this)), 0);

        // Finally, verify the connector called `adapter.send`
        bytes memory message = MessageLib.InitiateTransferShares(
            poolId.raw(), scId.raw(), OTHER_CHAIN_ID, centChainAddress, amount
        ).serialize();
        assertEq(adapter1.sent(message), 1);
    }

    function testTransferSharesFromCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        IShareToken shareToken = IShareToken(address(vault.share()));

        vm.expectRevert(IHook.TransferBlocked.selector);
        spoke.executeTransferShares(poolId, scId, destinationAddress.toBytes32(), amount);
        spoke.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );

        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.executeTransferShares(PoolId.wrap(poolId.raw() + 1), scId, destinationAddress.toBytes32(), amount);

        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));
        spoke.executeTransferShares(poolId, scId, destinationAddress.toBytes32(), amount);
        assertEq(shareToken.balanceOf(destinationAddress), amount);
    }

    function testTransferSharesToEVM(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            MessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );
        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            MessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with samount
        spoke.executeTransferShares(vault.poolId(), vault.scId(), address(this).toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            MessageLib.UpdateRestrictionMember(address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max).serialize(
            )
        );

        // fails for invalid share class token
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.transferShares{value: DEFAULT_GAS}(
            OTHER_CHAIN_ID, PoolId.wrap(poolId.raw() + 1), scId, destinationAddress.toBytes32(), amount
        );

        // Transfer amount from this address to destinationAddress
        spoke.transferShares{value: DEFAULT_GAS}(
            OTHER_CHAIN_ID, vault.poolId(), vault.scId(), destinationAddress.toBytes32(), amount
        );
        assertEq(shareToken.balanceOf(address(this)), 0);
    }

    function testUpdateMember(uint64 validUntil) public {
        validUntil = uint64(bound(validUntil, block.timestamp, type(uint64).max));
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(AsyncVault(vault_).share());

        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IMemberlist hook = IMemberlist(shareToken.hook());
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        hook.updateMember(address(shareToken), randomUser, validUntil);

        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.updateRestriction(
            PoolId.wrap(100),
            ShareClassId.wrap(bytes16(bytes("100"))),
            MessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize()
        ); // use random poolId & shareId

        spoke.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(address(0), randomUser, 0));
    }

    function testFreezeAndUnfreeze() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IShareToken shareToken = IShareToken(AsyncVault(vault_).share());
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address secondUser = makeAddr("secondUser");

        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.updateRestriction(
            PoolId.wrap(poolId.raw() + 1), scId, MessageLib.UpdateRestrictionFreeze(randomUser.toBytes32()).serialize()
        );

        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.updateRestriction(
            PoolId.wrap(poolId.raw() + 1),
            scId,
            MessageLib.UpdateRestrictionUnfreeze(randomUser.toBytes32()).serialize()
        );

        spoke.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize()
        );
        spoke.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(secondUser.toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionFreeze(randomUser.toBytes32()).serialize());
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionUnfreeze(randomUser.toBytes32()).serialize());
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionFreeze(secondUser.toBytes32()).serialize());
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        spoke.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionUnfreeze(secondUser.toBytes32()).serialize());
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));
    }

    function testUpdateShareMetadata() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        string memory updatedTokenName = "newName";
        string memory updatedTokenSymbol = "newSymbol";

        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.updateShareMetadata(
            PoolId.wrap(100), ShareClassId.wrap(bytes16(bytes("100"))), updatedTokenName, updatedTokenSymbol
        );

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        spoke.updateShareMetadata(poolId, scId, updatedTokenName, updatedTokenSymbol);

        assertEq(shareToken.name(), "name");
        assertEq(shareToken.symbol(), "symbol");

        spoke.updateShareMetadata(poolId, scId, updatedTokenName, updatedTokenSymbol);
        assertEq(shareToken.name(), updatedTokenName);
        assertEq(shareToken.symbol(), updatedTokenSymbol);

        vm.expectRevert(ISpoke.OldMetadata.selector);
        spoke.updateShareMetadata(poolId, scId, updatedTokenName, updatedTokenSymbol);
    }

    function testUpdateShareHook() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        address newHook = makeAddr("NewHook");

        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.updateShareHook(PoolId.wrap(100), ShareClassId.wrap(bytes16(bytes("100"))), newHook);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        spoke.updateShareHook(poolId, scId, newHook);

        assertEq(shareToken.hook(), fullRestrictionsHook);

        spoke.updateShareHook(poolId, scId, newHook);
        assertEq(shareToken.hook(), newHook);

        vm.expectRevert(ISpoke.OldHook.selector);
        spoke.updateShareHook(poolId, scId, newHook);
    }

    function testUpdateRestriction() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        bytes memory update = MessageLib.UpdateRestrictionFreeze(makeAddr("User").toBytes32()).serialize();

        vm.expectRevert(ISpoke.UnknownToken.selector);
        spoke.updateRestriction(PoolId.wrap(100), ShareClassId.wrap(bytes16(bytes("100"))), update);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        spoke.updateRestriction(poolId, scId, update);

        address hook = shareToken.hook();
        spoke.updateShareHook(poolId, scId, address(0));

        vm.expectRevert(ISpoke.InvalidHook.selector);
        spoke.updateRestriction(poolId, scId, update);

        spoke.updateShareHook(poolId, scId, hook);

        spoke.updateRestriction(poolId, scId, update);
    }

    function testUpdatePricePoolPerShareWorks(
        PoolId poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        ShareClassId scId,
        uint128 price,
        bytes32 salt
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(poolId.raw() > 0);
        vm.assume(scId.raw() > 0);
        spoke.addPool(poolId);
        AssetId assetId = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(erc20), 0);

        address hook = address(new MockHook());

        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp));

        spoke.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);

        spoke.updatePricePoolPerAsset(poolId, scId, assetId, 1e18, uint64(block.timestamp));

        vm.expectRevert(ISpoke.InvalidPrice.selector);
        spoke.priceAssetPerShare(poolId, scId, assetId, true);

        // Allows us to go back in time later
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        spoke.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        spoke.updatePricePoolPerAsset(poolId, scId, assetId, price, uint64(block.timestamp));

        spoke.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp));
        D18 latestPrice = spoke.priceAssetPerShare(poolId, scId, assetId, false);
        assertEq(latestPrice.raw(), price);

        vm.expectRevert(ISpoke.CannotSetOlderPrice.selector);
        spoke.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp - 1));

        // NOTE: We have no maxAge set, so price is invalid after timestamp of block increases
        vm.warp(block.timestamp + 1);
        vm.expectRevert(ISpoke.InvalidPrice.selector);
        spoke.priceAssetPerShare(poolId, scId, assetId, true);

        // NOTE: Unchecked version will work
        latestPrice = spoke.priceAssetPerShare(poolId, scId, assetId, false);
        assertEq(latestPrice.raw(), price);
    }

    function testVaultMigration() public {
        (, address oldVault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);

        AsyncVault oldVault = AsyncVault(oldVault_);
        PoolId poolId = oldVault.poolId();
        ShareClassId scId = oldVault.scId();
        address asset = address(oldVault.asset());

        AsyncVaultFactory newVaultFactory = new AsyncVaultFactory(address(root), asyncRequestManager, address(this));

        // rewire factory contracts
        newVaultFactory.rely(address(spoke));
        asyncRequestManager.rely(address(newVaultFactory));
        spoke.file("vaultFactory", address(newVaultFactory), true);

        // Unlink old vault
        spoke.unlinkVault(poolId, scId, AssetId.wrap(assetId), oldVault);
        assertEq(spoke.shareToken(poolId, scId).vault(asset), address(0));

        // Deploy and link new vault
        IBaseVault newVault = spoke.deployVault(poolId, scId, AssetId.wrap(assetId), newVaultFactory);
        assert(oldVault_ != address(newVault));
        spoke.linkVault(poolId, scId, AssetId.wrap(assetId), newVault);
        assertEq(spoke.shareToken(poolId, scId).vault(asset), address(newVault));
    }

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
            MessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );
        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            MessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );

        assertTrue(shareToken.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with amount
        spoke.executeTransferShares(vault.poolId(), vault.scId(), address(this).toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        // fails for invalid share class token
        PoolId poolId = vault.poolId();
        ShareClassId scId = vault.scId();

        spoke.updateRestriction(poolId, scId, MessageLib.UpdateRestrictionFreeze(address(this).toBytes32()).serialize());
        assertFalse(shareToken.checkTransferRestriction(address(this), destinationAddress, 0));

        vm.expectRevert(ISpoke.CrossChainTransferNotAllowed.selector);
        spoke.transferShares{value: DEFAULT_GAS}(OTHER_CHAIN_ID, poolId, scId, destinationAddress.toBytes32(), amount);

        spoke.updateRestriction(
            vault.poolId(),
            vault.scId(),
            MessageLib.UpdateRestrictionMember(address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max).serialize(
            )
        );

        vm.expectRevert(ISpoke.CrossChainTransferNotAllowed.selector);
        spoke.transferShares{value: DEFAULT_GAS}(OTHER_CHAIN_ID, poolId, scId, destinationAddress.toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        spoke.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionUnfreeze(address(this).toBytes32()).serialize()
        );
        spoke.transferShares{value: DEFAULT_GAS}(OTHER_CHAIN_ID, poolId, scId, destinationAddress.toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(poolEscrowFactory.escrow(poolId))), 0);
    }

    function testLinkVaultInvalidShare(PoolId poolId, ShareClassId scId) public {
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.linkVault(poolId, scId, AssetId.wrap(defaultAssetId), IBaseVault(address(0)));
    }

    function testUnlinkVaultInvalidShare(PoolId poolId, ShareClassId scId) public {
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.unlinkVault(poolId, scId, AssetId.wrap(defaultAssetId), IBaseVault(address(0)));
    }

    function testLinkVaultUnauthorized(PoolId poolId, ShareClassId scId) public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.linkVault(poolId, scId, AssetId.wrap(defaultAssetId), IBaseVault(address(0)));
    }

    function testUnlinkVaultUnauthorized(PoolId poolId, ShareClassId scId) public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.unlinkVault(poolId, scId, AssetId.wrap(defaultAssetId), IBaseVault(address(0)));
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
            assert(spoke.isLinked(poolId, scId, asset, IBaseVault(vaultAddress)));

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
            assert(!spoke.isLinked(poolId, scId, asset, IBaseVault(vaultAddress)));

            // Check missing link
            assertEq(vault_, address(0), "Share link to vault requires linkVault");
            assertEq(
                asyncRequestManager.wards(vaultAddress), 0, "Vault auth on asyncRequestManager set up in linkVault"
            );
        }
    }

    function _assertShareSetup(address vaultAddress, bool isLinked) private view {
        IShareToken token_ = spoke.shareToken(poolId, scId);
        ShareToken shareToken = ShareToken(address(token_));

        assertEq(shareToken.wards(address(spoke)), 1);
        assertEq(shareToken.wards(address(this)), 0);

        assertEq(shareToken.name(), tokenName, "share class token name mismatch");
        assertEq(shareToken.symbol(), tokenSymbol, "share class token symbol mismatch");
        assertEq(shareToken.decimals(), decimals, "share class token decimals mismatch");

        if (isLinked) {
            assertEq(shareToken.wards(vaultAddress), 1);
        } else {
            assertEq(shareToken.wards(vaultAddress), 0, "Vault auth on Share set up in linkVault");
        }
    }

    function _assertDeployedVault(address vaultAddress, AssetId assetId, address asset, uint256 tokenId, bool isLinked)
        internal
        view
    {
        _assertVaultSetup(vaultAddress, assetId, asset, tokenId, isLinked);
        _assertShareSetup(vaultAddress, isLinked);
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
        vm.expectEmit(true, true, true, false);
        emit ISpoke.DeployVault(
            poolId, scId, asset, erc20TokenId, asyncVaultFactory, IBaseVault(address(0)), VaultKind.Async
        );
        IBaseVault vault = spoke.deployVault(poolId, scId, assetId, asyncVaultFactory);

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
        IBaseVault vault = spoke.deployVault(poolId, scId, assetId, asyncVaultFactory);

        vm.expectEmit(true, true, true, false);
        emit ISpoke.LinkVault(poolId, scId, asset, erc20TokenId, vault);
        spoke.linkVault(poolId, scId, assetId, vault);

        _assertDeployedVault(address(vault), assetId, asset, erc20TokenId, true);
    }

    function testDeploVaultInvalidShare(PoolId poolId, ShareClassId scId) public {
        vm.expectRevert(ISpoke.ShareTokenDoesNotExist.selector);
        spoke.deployVault(poolId, scId, AssetId.wrap(defaultAssetId), asyncVaultFactory);
    }

    function testDeploVaultInvalidVaultFactory(
        PoolId poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        ShareClassId scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        vm.expectRevert(ISpoke.InvalidFactory.selector);
        spoke.deployVault(poolId, scId, AssetId.wrap(defaultAssetId), IVaultFactory(address(0)));
    }

    function testDeployVaultUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.deployVault(PoolId.wrap(0), ShareClassId.wrap(0), AssetId.wrap(0), IVaultFactory(address(0)));
    }
}

contract SpokeRegisterAssetTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;
    using BytesLib for *;

    uint32 constant STORAGE_INDEX_ASSET_COUNTER = 4;
    uint256 constant STORAGE_OFFSET_ASSET_COUNTER = 20;

    function _assertAssetCounterEq(uint32 expected) internal view {
        bytes32 slotData = vm.load(address(spoke), bytes32(uint256(STORAGE_INDEX_ASSET_COUNTER)));

        // Extract `_assetCounter` at offset 20 bytes (rightmost 4 bytes)
        uint32 assetCounter = uint32(uint256(slotData >> (STORAGE_OFFSET_ASSET_COUNTER * 8)));
        assertEq(assetCounter, expected, "Asset counter does not match expected value");
    }

    function _assertAssetRegistered(address asset, AssetId assetId, uint256 tokenId, uint32 expectedAssetCounter)
        internal
        view
    {
        assertEq(spoke.assetToId(asset, tokenId).raw(), assetId.raw(), "Asset to id mismatch");
        (address asset_, uint256 tokenId_) = spoke.idToAsset(assetId);
        assertEq(asset_, asset);
        assertEq(tokenId_, tokenId);
        _assertAssetCounterEq(expectedAssetCounter);
    }

    function testRegisterSingleAssetERC20() public {
        address asset = address(erc20);
        bytes memory message =
            MessageLib.RegisterAsset({assetId: defaultAssetId, decimals: erc20.decimals()}).serialize();

        vm.expectEmit();
        emit ISpoke.RegisterAsset(
            AssetId.wrap(defaultAssetId), asset, 0, erc20.name(), erc20.symbol(), erc20.decimals()
        );
        vm.expectEmit(false, false, false, false);
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), message);
        AssetId assetId = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, asset, 0);

        assertEq(assetId.raw(), defaultAssetId);

        // Allowance is set during vault deployment
        assertEq(erc20.allowance(address(poolEscrowFactory.escrow(POOL_A)), address(spoke)), 0);
        _assertAssetRegistered(asset, assetId, 0, 1);
    }

    function testRegisterMultipleAssetsERC20(string calldata name, string calldata symbol, uint8 decimals) public {
        decimals = uint8(bound(decimals, 2, 18));

        ERC20 assetA = erc20;
        ERC20 assetB = _newErc20(name, symbol, decimals);

        AssetId assetIdA = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(assetA), 0);
        _assertAssetRegistered(address(assetA), assetIdA, 0, 1);

        AssetId assetIdB = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(assetB), 0);
        _assertAssetRegistered(address(assetB), assetIdB, 0, 2);

        assert(assetIdA.raw() != assetIdB.raw());
    }

    function testRegisterSingleAssetERC20_emptyNameSymbol() public {
        ERC20 asset = _newErc20("", "", 10);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(asset), 0);
        _assertAssetRegistered(address(asset), AssetId.wrap(defaultAssetId), 0, 1);
    }

    function testRegisterSingleAssetERC6909(uint8 decimals) public {
        uint256 tokenId = uint256(bound(decimals, 2, 18));
        MockERC6909 erc6909 = new MockERC6909();
        address asset = address(erc6909);

        bytes memory message =
            MessageLib.RegisterAsset({assetId: defaultAssetId, decimals: erc6909.decimals(tokenId)}).serialize();

        vm.expectEmit();
        emit ISpoke.RegisterAsset(
            AssetId.wrap(defaultAssetId),
            asset,
            tokenId,
            erc6909.name(tokenId),
            erc6909.symbol(tokenId),
            erc6909.decimals(tokenId)
        );
        vm.expectEmit(false, false, false, false);
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), message);
        AssetId assetId = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, asset, tokenId);

        assertEq(assetId.raw(), defaultAssetId);

        // Allowance is set during vault deployment
        assertEq(erc6909.allowance(address(poolEscrowFactory.escrow(POOL_A)), address(spoke), tokenId), 0);
        _assertAssetRegistered(asset, assetId, tokenId, 1);
    }

    function testRegisterMultipleAssetsERC6909(uint8 decimals) public {
        MockERC6909 erc6909 = new MockERC6909();
        uint256 tokenIdA = uint256(bound(decimals, 3, 18));
        uint256 tokenIdB = uint256(bound(decimals, 2, tokenIdA - 1));

        AssetId assetIdA = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(erc6909), tokenIdA);
        _assertAssetRegistered(address(erc6909), assetIdA, tokenIdA, 1);

        AssetId assetIdB = spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(erc6909), tokenIdB);
        _assertAssetRegistered(address(erc6909), assetIdB, tokenIdB, 2);

        assert(assetIdA.raw() != assetIdB.raw());
    }

    function testRegisterAssetTwice() public {
        vm.expectEmit();
        emit ISpoke.RegisterAsset(
            AssetId.wrap(defaultAssetId), address(erc20), 0, erc20.name(), erc20.symbol(), erc20.decimals()
        );
        vm.expectEmit(false, false, false, false);
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), bytes(""));
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), bytes(""));
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(erc20), 0);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(erc20), 0);
    }

    function testRegisterAsset_decimalsMissing() public {
        address asset = address(new MockERC6909());
        vm.expectRevert(ISpoke.AssetMissingDecimals.selector);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, asset, 0);
    }

    function testRegisterAsset_invalidContract(uint256 tokenId) public {
        vm.expectRevert(ISpoke.AssetMissingDecimals.selector);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(0), tokenId);
    }

    function testRegisterAssetERC20_decimalDeficit() public {
        ERC20 asset = _newErc20("", "", 1);
        vm.expectRevert(ISpoke.TooFewDecimals.selector);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(asset), 0);
    }

    function testRegisterAssetERC20_decimalExcess() public {
        ERC20 asset = _newErc20("", "", 19);
        vm.expectRevert(ISpoke.TooManyDecimals.selector);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(asset), 0);
    }

    function testRegisterAssetERC6909_decimalDeficit() public {
        MockERC6909 asset = new MockERC6909();
        vm.expectRevert(ISpoke.TooFewDecimals.selector);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(asset), 1);
    }

    function testRegisterAssetERC6909_decimalExcess() public {
        MockERC6909 asset = new MockERC6909();
        vm.expectRevert(ISpoke.TooManyDecimals.selector);
        spoke.registerAsset{value: DEFAULT_GAS}(OTHER_CHAIN_ID, address(asset), 19);
    }
}

contract UpdateContractMock is IUpdateContract {
    IUpdateContract immutable spoke;

    constructor(address spoke_) {
        spoke = IUpdateContract(spoke_);
    }

    function update(PoolId poolId, ShareClassId scId, bytes calldata payload) public {
        spoke.update(poolId, scId, payload);
    }
}

contract SpokeUpdateContract is BaseTest, SpokeTestHelper {
    using MessageLib for *;

    /*
    function testUpdateContractTargetThis(
        PoolId poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        ShareClassId scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(asyncVaultFactory);

        vm.expectEmit();
        emit ISpoke.UpdateContract(poolId, scId, address(spoke), vaultUpdate);
        spoke.updateContract(poolId, scId, address(spoke), vaultUpdate);
    }

    function testUpdateContractTargetUpdateContractMock(
        PoolId poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        ShareClassId scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(asyncVaultFactory);
        UpdateContractMock mock = new UpdateContractMock(address(spoke));
        IAuth(address(spoke)).rely(address(mock));

        vm.expectEmit();
        emit ISpoke.UpdateContract(poolId, scId, address(mock), vaultUpdate);
        spoke.updateContract(poolId, scId, address(mock), vaultUpdate);
    }
    */

    function testUpdateContractUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.updateContract(PoolId.wrap(0), ShareClassId.wrap(bytes16(0)), address(0), bytes(""));
    }

    function testUpdateUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        spoke.update(PoolId.wrap(0), ShareClassId.wrap(0), bytes(""));
    }

    /*
    function _serializedUpdateContractNewVault(IVaultFactory vaultFactory_)
        internal
        view
        returns (bytes memory payload)
    {
        return MessageLib.UpdateContractVaultUpdate({
            vaultOrFactory: bytes32(bytes20(address(vaultFactory_))),
            assetId: assetIdErc20.raw(),
            kind: uint8(VaultUpdateKind.DeployAndLink)
        }).serialize();
    }
    */
}

contract SpokeUpdateVault is SpokeTestHelper {
    function testUpdateContractUnknownVault(
        PoolId poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        ShareClassId scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);
        registerAssetErc20();

        vm.expectRevert(ISpoke.UnknownVault.selector);
        spoke.updateVault(poolId, scId, assetIdErc20, address(1), VaultUpdateKind.Link);
    }
}
