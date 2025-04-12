// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";
import {MockHook} from "test/vaults/mocks/MockHook.sol";
import "test/vaults/BaseTest.sol";

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {D18} from "src/misc/types/D18.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseVault} from "src/vaults/interfaces/IERC7540.sol";
import {IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";
import {IHook} from "src/vaults/interfaces/token/IHook.sol";

import {IRestrictedTransfers} from "src/hooks/interfaces/IRestrictedTransfers.sol";

contract PoolManagerTestHelper is BaseTest {
    uint64 poolId;
    uint8 decimals;
    string tokenName;
    string tokenSymbol;
    bytes16 scId;
    address assetErc20;
    uint128 assetIdErc20;

    // helpers
    function hasDuplicates(bytes16[4] calldata array) internal pure returns (bool) {
        uint256 length = array.length;
        for (uint256 i = 0; i < length; i++) {
            for (uint256 j = i + 1; j < length; j++) {
                if (array[i] == array[j]) {
                    return true;
                }
            }
        }
        return false;
    }

    function setUpPoolAndShare(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        decimals_ = uint8(bound(decimals_, 2, 18));
        vm.assume(bytes(tokenName_).length <= 128);
        vm.assume(bytes(tokenSymbol_).length <= 32);

        poolId = poolId_;
        decimals = decimals_;
        tokenName = tokenName;
        tokenSymbol = tokenSymbol_;
        scId = scId_;

        poolManager.addPool(poolId);
        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, bytes32(0), address(new MockHook()));
    }

    function registerAssetErc20() public {
        assetErc20 = address(_newErc20(tokenName, tokenSymbol, decimals));
        assetIdErc20 = poolManager.registerAsset(OTHER_CHAIN_ID, assetErc20, 0);
    }
}

contract PoolManagerTest is BaseTest, PoolManagerTestHelper {
    using MessageLib for *;
    using CastLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(
            nonWard != address(root) && nonWard != address(vaultRouter) && nonWard != address(this)
                && nonWard != address(messageProcessor) && nonWard != address(messageDispatcher)
                && nonWard != address(gateway)
        );

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = address(asyncVaultFactory);

        // redeploying within test to increase coverage
        new PoolManager(address(escrow), tokenFactory, vaultFactories);

        // values set correctly
        assertEq(address(poolManager.escrow()), address(escrow));
        assertEq(address(asyncRequests.poolManager()), address(poolManager));
        assertEq(address(syncRequests.poolManager()), address(poolManager));
        assertEq(address(messageDispatcher), address(poolManager.sender()));

        // permissions set correctly
        assertEq(poolManager.wards(address(root)), 1);
        assertEq(poolManager.wards(address(gateway)), 1);
        assertEq(poolManager.wards(address(vaultRouter)), 1);
        assertEq(escrow.wards(address(poolManager)), 1);
        assertEq(poolManager.wards(nonWard), 0);
    }

    function testFile() public {
        address newSender = makeAddr("newSender");
        vm.expectEmit();
        emit IPoolManager.File("sender", newSender);
        poolManager.file("sender", newSender);
        assertEq(address(poolManager.sender()), newSender);

        address newBalanceSheet = makeAddr("newBalanceSheet");
        vm.expectEmit();
        emit IPoolManager.File("balanceSheet", newBalanceSheet);
        poolManager.file("balanceSheet", newBalanceSheet);
        assertEq(poolManager.balanceSheet(), newBalanceSheet);

        address newTokenFactory = makeAddr("newTokenFactory");
        vm.expectEmit();
        emit IPoolManager.File("tokenFactory", newTokenFactory);
        poolManager.file("tokenFactory", newTokenFactory);
        assertEq(address(poolManager.tokenFactory()), newTokenFactory);

        address newVaultFactory = makeAddr("newVaultFactory");
        assertEq(poolManager.vaultFactory(newVaultFactory), false);
        poolManager.file("vaultFactory", newVaultFactory, true);
        assertEq(poolManager.vaultFactory(newVaultFactory), true);
        assertEq(poolManager.vaultFactory(asyncVaultFactory), true);

        vm.expectEmit();
        emit IPoolManager.File("vaultFactory", newVaultFactory, false);
        poolManager.file("vaultFactory", newVaultFactory, false);
        assertEq(poolManager.vaultFactory(newVaultFactory), false);

        address newEscrow = makeAddr("newEscrow");
        vm.expectRevert(IPoolManager.FileUnrecognizedParam.selector);
        poolManager.file("escrow", newEscrow);

        vm.expectRevert(IPoolManager.FileUnrecognizedParam.selector);
        poolManager.file("escrow", newEscrow, true);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.file("", address(0));

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.file("", address(0), true);
    }

    function testAddPool(uint64 poolId) public {
        poolManager.addPool(poolId);

        vm.expectRevert(IPoolManager.PoolAlreadyAdded.selector);
        poolManager.addPool(poolId);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.addPool(poolId);
    }

    function testAddShareClass(
        uint64 poolId,
        bytes16 scId,
        string memory tokenName,
        string memory tokenSymbol,
        bytes32 salt,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());

        vm.expectRevert(IPoolManager.InvalidPool.selector);
        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);
        poolManager.addPool(poolId);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);

        vm.expectRevert(IPoolManager.TooFewDecimals.selector);
        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, 0, bytes32(0), hook);

        vm.expectRevert(IPoolManager.TooManyDecimals.selector);
        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, 19, bytes32(0), hook);

        vm.expectRevert(IPoolManager.InvalidHook.selector);
        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, address(1));

        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);
        CentrifugeToken shareToken = CentrifugeToken(poolManager.shareToken(poolId, scId));
        assertEq(tokenName, shareToken.name());
        assertEq(tokenSymbol, shareToken.symbol());
        assertEq(decimals, shareToken.decimals());
        assertEq(hook, shareToken.hook());

        vm.expectRevert(IPoolManager.ShareClassAlreadyRegistered.selector);
        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);
    }

    function testAddMultipleSharesWorks(
        uint64 poolId,
        bytes16[4] calldata scIds,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(!hasDuplicates(scIds));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        poolManager.addPool(poolId);

        address hook = address(new MockHook());

        for (uint256 i = 0; i < scIds.length; i++) {
            poolManager.addShareClass(poolId, scIds[i], tokenName, tokenSymbol, decimals, bytes32(i), hook);
            CentrifugeToken shareToken = CentrifugeToken(poolManager.shareToken(poolId, scIds[i]));
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
        poolManager.updateRestriction(
            vault.poolId(),
            vault.trancheId(),
            MessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );

        poolManager.handleTransferShares(vault.poolId(), vault.trancheId(), address(this), amount);
        assertEq(shareToken.balanceOf(address(this)), amount); // Verify the address(this) has the expected amount

        poolManager.updateRestriction(
            vault.poolId(),
            vault.trancheId(),
            MessageLib.UpdateRestrictionMember(address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max).serialize(
            )
        );

        // fails for invalid share class token
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();
        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.transferShares(OTHER_CHAIN_ID, poolId + 1, scId, centChainAddress, amount);

        // send the transfer from EVM -> Cent Chain
        shareToken.approve(address(poolManager), amount);
        poolManager.transferShares(OTHER_CHAIN_ID, poolId, scId, centChainAddress, amount);
        assertEq(shareToken.balanceOf(address(this)), 0);

        // Finally, verify the connector called `adapter.send`
        bytes memory message = MessageLib.TransferShares(poolId, scId, centChainAddress, amount).serialize();
        assertEq(adapter1.sent(message), 1);
    }

    function testTransferSharesUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.transferShares(0, 0, bytes16(0), 0, 0);
    }

    function testTransferSharesFromCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();

        IShareToken shareToken = IShareToken(address(vault.share()));

        vm.expectRevert(IHook.TransferBlocked.selector);
        poolManager.handleTransferShares(poolId, scId, destinationAddress, amount);
        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );

        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.handleTransferShares(poolId + 1, scId, destinationAddress, amount);

        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));
        poolManager.handleTransferShares(poolId, scId, destinationAddress, amount);
        assertEq(shareToken.balanceOf(destinationAddress), amount);
    }

    function testTransferSharesToEVM(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        poolManager.updateRestriction(
            vault.poolId(),
            vault.trancheId(),
            MessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );
        poolManager.updateRestriction(
            vault.poolId(),
            vault.trancheId(),
            MessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with samount
        poolManager.handleTransferShares(vault.poolId(), vault.trancheId(), address(this), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        // fails for invalid share class token
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();
        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.transferShares(OTHER_CHAIN_ID, poolId + 1, scId, destinationAddress.toBytes32(), amount);

        // Approve and transfer amount from this address to destinationAddress
        shareToken.approve(address(poolManager), amount);
        poolManager.transferShares(
            OTHER_CHAIN_ID, vault.poolId(), vault.trancheId(), destinationAddress.toBytes32(), amount
        );
        assertEq(shareToken.balanceOf(address(this)), 0);
    }

    function testUpdateMember(uint64 validUntil) public {
        validUntil = uint64(bound(validUntil, block.timestamp, type(uint64).max));
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();
        IRestrictedTransfers hook = IRestrictedTransfers(shareToken.hook());
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        hook.updateMember(address(shareToken), randomUser, validUntil);

        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.updateRestriction(
            100,
            bytes16(bytes("100")),
            MessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize()
        ); // use random poolId & shareId

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(address(0), randomUser, 0));

        vm.expectRevert(IRestrictedTransfers.EndorsedUserCannotBeUpdated.selector);
        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(address(escrow).toBytes32(), validUntil).serialize()
        );
    }

    function testFreezeAndUnfreeze() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address secondUser = makeAddr("secondUser");

        vm.expectRevert(IRestrictedTransfers.EndorsedUserCannotBeFrozen.selector);
        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionFreeze(address(escrow).toBytes32()).serialize()
        );

        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.updateRestriction(
            poolId + 1, scId, MessageLib.UpdateRestrictionFreeze(randomUser.toBytes32()).serialize()
        );

        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.updateRestriction(
            poolId + 1, scId, MessageLib.UpdateRestrictionUnfreeze(randomUser.toBytes32()).serialize()
        );

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(randomUser.toBytes32(), validUntil).serialize()
        );
        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionMember(secondUser.toBytes32(), validUntil).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionFreeze(randomUser.toBytes32()).serialize()
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionUnfreeze(randomUser.toBytes32()).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionFreeze(secondUser.toBytes32()).serialize()
        );
        assertFalse(shareToken.checkTransferRestriction(randomUser, secondUser, 0));

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionUnfreeze(secondUser.toBytes32()).serialize()
        );
        assertTrue(shareToken.checkTransferRestriction(randomUser, secondUser, 0));
    }

    function testUpdateShareMetadata() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        string memory updatedTokenName = "newName";
        string memory updatedTokenSymbol = "newSymbol";

        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.updateShareMetadata(100, bytes16(bytes("100")), updatedTokenName, updatedTokenSymbol);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateShareMetadata(poolId, scId, updatedTokenName, updatedTokenSymbol);

        assertEq(shareToken.name(), "name");
        assertEq(shareToken.symbol(), "symbol");

        poolManager.updateShareMetadata(poolId, scId, updatedTokenName, updatedTokenSymbol);
        assertEq(shareToken.name(), updatedTokenName);
        assertEq(shareToken.symbol(), updatedTokenSymbol);

        vm.expectRevert(IPoolManager.OldMetadata.selector);
        poolManager.updateShareMetadata(poolId, scId, updatedTokenName, updatedTokenSymbol);
    }

    function testUpdateShareHook() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        address newHook = makeAddr("NewHook");

        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.updateShareHook(100, bytes16(bytes("100")), newHook);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateShareHook(poolId, scId, newHook);

        assertEq(shareToken.hook(), restrictedTransfers);

        poolManager.updateShareHook(poolId, scId, newHook);
        assertEq(shareToken.hook(), newHook);

        vm.expectRevert(IPoolManager.OldHook.selector);
        poolManager.updateShareHook(poolId, scId, newHook);
    }

    function testUpdateRestriction() public {
        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));

        bytes memory update = MessageLib.UpdateRestrictionFreeze(makeAddr("User").toBytes32()).serialize();

        vm.expectRevert(IPoolManager.UnknownToken.selector);
        poolManager.updateRestriction(100, bytes16(bytes("100")), update);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateRestriction(poolId, scId, update);

        address hook = shareToken.hook();
        poolManager.updateShareHook(poolId, scId, address(0));

        vm.expectRevert(IPoolManager.InvalidHook.selector);
        poolManager.updateRestriction(poolId, scId, update);

        poolManager.updateShareHook(poolId, scId, hook);

        poolManager.updateRestriction(poolId, scId, update);
    }

    function testUpdatePricePoolPerShareWorks(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 scId,
        uint128 price,
        bytes32 salt
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(poolId > 0);
        vm.assume(scId > 0);
        poolManager.addPool(poolId);
        uint128 assetId = poolManager.registerAsset(OTHER_CHAIN_ID, address(erc20), 0);

        address hook = address(new MockHook());

        vm.expectRevert(IPoolManager.ShareTokenDoesNotExist.selector);
        poolManager.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp));

        poolManager.addShareClass(poolId, scId, tokenName, tokenSymbol, decimals, salt, hook);

        poolManager.updatePricePoolPerAsset(poolId, scId, assetId, 1e18, uint64(block.timestamp));

        vm.expectRevert(IPoolManager.InvalidPrice.selector);
        poolManager.priceAssetPerShare(poolId, scId, assetId, true);

        // Allows us to go back in time later
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updatePricePoolPerAsset(poolId, scId, assetId, price, uint64(block.timestamp));

        poolManager.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp));
        (D18 latestPrice, uint64 lastUpdated) = poolManager.priceAssetPerShare(poolId, scId, assetId, false);
        assertEq(latestPrice.raw(), price);
        assertEq(lastUpdated, block.timestamp);

        vm.expectRevert(IPoolManager.CannotSetOlderPrice.selector);
        poolManager.updatePricePoolPerShare(poolId, scId, price, uint64(block.timestamp - 1));

        // NOTE: We have no maxAge set, so price is invalid after timestamp of block increases
        vm.warp(block.timestamp + 1);
        vm.expectRevert(IPoolManager.InvalidPrice.selector);
        poolManager.priceAssetPerShare(poolId, scId, assetId, true);

        // NOTE: Unchecked version will work
        (latestPrice, lastUpdated) = poolManager.priceAssetPerShare(poolId, scId, assetId, false);
        assertEq(latestPrice.raw(), price);
        assertEq(lastUpdated, block.timestamp - 1);
    }

    function testVaultMigration() public {
        (, address oldVault_, uint128 assetId) = deploySimpleVault(VaultKind.Async);

        AsyncVault oldVault = AsyncVault(oldVault_);
        uint64 poolId = oldVault.poolId();
        bytes16 scId = oldVault.trancheId();
        address asset = address(oldVault.asset());

        AsyncVaultFactory newVaultFactory = new AsyncVaultFactory(address(root), address(asyncRequests));

        // rewire factory contracts
        newVaultFactory.rely(address(poolManager));
        asyncRequests.rely(address(newVaultFactory));
        poolManager.file("vaultFactory", address(newVaultFactory), true);

        // Remove old vault
        address vaultManager = address(IBaseVault(oldVault_).manager());
        IVaultManager(vaultManager).removeVault(poolId, scId, oldVault_, asset, assetId);
        assertEq(CentrifugeToken(poolManager.shareToken(poolId, scId)).vault(asset), address(0));

        // Deploy new vault
        address newVault = poolManager.deployVault(poolId, scId, assetId, address(newVaultFactory));
        assert(oldVault_ != newVault);
    }

    function testPoolManagerCannotTransferSharesOnAccountRestrictions(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (, address vault_,) = deploySimpleVault(VaultKind.Async);
        AsyncVault vault = AsyncVault(vault_);
        IShareToken shareToken = IShareToken(address(AsyncVault(vault_).share()));
        shareToken.approve(address(poolManager), amount);

        poolManager.updateRestriction(
            vault.poolId(),
            vault.trancheId(),
            MessageLib.UpdateRestrictionMember(destinationAddress.toBytes32(), validUntil).serialize()
        );
        poolManager.updateRestriction(
            vault.poolId(),
            vault.trancheId(),
            MessageLib.UpdateRestrictionMember(address(this).toBytes32(), validUntil).serialize()
        );

        assertTrue(shareToken.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(shareToken.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with amount
        poolManager.handleTransferShares(vault.poolId(), vault.trancheId(), address(this), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        // fails for invalid share class token
        uint64 poolId = vault.poolId();
        bytes16 scId = vault.trancheId();

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionFreeze(address(this).toBytes32()).serialize()
        );
        assertFalse(shareToken.checkTransferRestriction(address(this), destinationAddress, 0));

        vm.expectRevert(IPoolManager.CrossChainTransferNotAllowed.selector);
        poolManager.transferShares(OTHER_CHAIN_ID, poolId, scId, destinationAddress.toBytes32(), amount);

        poolManager.updateRestriction(
            vault.poolId(),
            vault.trancheId(),
            MessageLib.UpdateRestrictionMember(address(uint160(OTHER_CHAIN_ID)).toBytes32(), type(uint64).max).serialize(
            )
        );

        vm.expectRevert(IHook.TransferBlocked.selector);
        poolManager.transferShares{value: 1 ether}(OTHER_CHAIN_ID, poolId, scId, destinationAddress.toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(this)), amount);

        poolManager.updateRestriction(
            poolId, scId, MessageLib.UpdateRestrictionUnfreeze(address(this).toBytes32()).serialize()
        );
        poolManager.transferShares(OTHER_CHAIN_ID, poolId, scId, destinationAddress.toBytes32(), amount);
        assertEq(shareToken.balanceOf(address(escrow)), 0);
    }

    function testLinkVaultInvalidShare(uint64 poolId, bytes16 scId) public {
        vm.expectRevert(IPoolManager.ShareTokenDoesNotExist.selector);
        poolManager.linkVault(poolId, scId, defaultAssetId, address(0));
    }

    function testUnlinkVaultInvalidShare(uint64 poolId, bytes16 scId) public {
        vm.expectRevert(IPoolManager.ShareTokenDoesNotExist.selector);
        poolManager.unlinkVault(poolId, scId, defaultAssetId, address(0));
    }

    function testLinkVaultUnauthorized(uint64 poolId, bytes16 scId) public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.linkVault(poolId, scId, defaultAssetId, address(0));
    }

    function testUnlinkVaultUnauthorized(uint64 poolId, bytes16 scId) public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.unlinkVault(poolId, scId, defaultAssetId, address(0));
    }
}

contract PoolManagerDeployVaultTest is BaseTest, PoolManagerTestHelper {
    using MessageLib for *;
    using CastLib for *;
    using BytesLib for *;

    function _assertVaultSetup(address vaultAddress, uint128 assetId, address asset, uint256 tokenId, bool isLinked)
        private
        view
    {
        address vaultManager = address(IBaseVault(vaultAddress).manager());
        address token_ = poolManager.shareToken(poolId, scId);
        address vault_ = IShareToken(token_).vault(asset);

        assert(poolManager.isPoolActive(poolId));

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddress);
        assertEq(assetId, vaultDetails.assetId, "vault assetId mismatch");
        assertEq(asset, vaultDetails.asset, "vault asset mismatch");
        assertEq(tokenId, vaultDetails.tokenId, "vault asset mismatch");
        assertEq(false, vaultDetails.isWrapper, "vault isWrapper mismatch");
        assertEq(isLinked, vaultDetails.isLinked, "vault isLinked mismatch");

        if (isLinked) {
            assert(poolManager.isLinked(poolId, scId, asset, vaultAddress));

            // check vault state
            assertEq(vaultAddress, vault_, "vault address mismatch");
            AsyncVault vault = AsyncVault(vault_);
            assertEq(address(vault.manager()), address(asyncRequests), "investment manager mismatch");
            assertEq(vault.asset(), asset, "asset mismatch");
            assertEq(vault.poolId(), poolId, "poolId mismatch");
            assertEq(vault.trancheId(), scId, "scId mismatch");
            assertEq(address(vault.share()), token_, "share class token mismatch");

            assertEq(vault.wards(address(asyncRequests)), 1);
            assertEq(vault.wards(address(this)), 0);
            assertEq(asyncRequests.wards(vaultAddress), 1);
        } else {
            assert(!poolManager.isLinked(poolId, scId, asset, vaultAddress));
            // Check Share permissions
            assertEq(CentrifugeToken(token_).wards(vaultManager), 1);

            // Check missing link
            assertEq(vault_, address(0), "Share link to vault requires linkVault");
            assertEq(asyncRequests.wards(vaultAddress), 0, "Vault auth on asyncRequests set up in linkVault");
        }
    }

    function _assertShareSetup(address vaultAddress, bool isLinked) private view {
        address token_ = poolManager.shareToken(poolId, scId);
        CentrifugeToken shareToken = CentrifugeToken(token_);

        assertEq(shareToken.wards(address(poolManager)), 1);
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

    function _assertAllowance(address vaultAddress, address asset, uint256 tokenId) private view {
        address vaultManager = address(IBaseVault(vaultAddress).manager());
        address escrow_ = address(poolManager.escrow());
        address token_ = poolManager.shareToken(poolId, scId);

        assertEq(IERC20(token_).allowance(escrow_, vaultManager), type(uint256).max, "Share token allowance missing");

        if (tokenId == 0) {
            assertEq(IERC20(asset).allowance(escrow_, vaultManager), type(uint256).max, "ERC20 Asset allowance missing");
        } else {
            assertEq(
                IERC6909(asset).allowance(escrow_, vaultManager, tokenId),
                type(uint256).max,
                "ERC6909 Asset allowance missing"
            );
        }
    }

    function _assertDeployedVault(address vaultAddress, uint128 assetId, address asset, uint256 tokenId, bool isLinked)
        internal
        view
    {
        _assertVaultSetup(vaultAddress, assetId, asset, tokenId, isLinked);
        _assertShareSetup(vaultAddress, isLinked);
        _assertAllowance(vaultAddress, asset, tokenId);
    }

    function testDeployVaultWithoutLinkERC20(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        address asset = address(erc20);

        // Check event except for vault address which cannot be known
        (uint128 assetId) = poolManager.registerAsset(OTHER_CHAIN_ID, asset, erc20TokenId);
        vm.expectEmit(true, true, true, false);
        emit IPoolManager.DeployVault(poolId, scId, asset, erc20TokenId, asyncVaultFactory, address(0));
        address vaultAddress = poolManager.deployVault(poolId, scId, assetId, asyncVaultFactory);

        _assertDeployedVault(vaultAddress, assetId, asset, erc20TokenId, false);
    }

    function testDeployVaultWithLinkERC20(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        address asset = address(erc20);

        (uint128 assetId) = poolManager.registerAsset(OTHER_CHAIN_ID, asset, erc20TokenId);
        address vaultAddress = poolManager.deployVault(poolId, scId, assetId, asyncVaultFactory);

        vm.expectEmit(true, true, true, false);
        emit IPoolManager.LinkVault(poolId, scId, asset, erc20TokenId, vaultAddress);
        poolManager.linkVault(poolId, scId, assetId, vaultAddress);

        _assertDeployedVault(vaultAddress, assetId, asset, erc20TokenId, true);
    }

    function testDeployVaultWithoutLinkERC6909(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        uint256 tokenId = decimals;
        address asset = address(new MockERC6909());

        // Check event except for vault address which cannot be known
        (uint128 assetId) = poolManager.registerAsset(OTHER_CHAIN_ID, asset, tokenId);
        vm.expectEmit(true, true, true, false);
        emit IPoolManager.DeployVault(poolId, scId, asset, tokenId, asyncVaultFactory, address(0));
        address vaultAddress = poolManager.deployVault(poolId, scId, assetId, asyncVaultFactory);

        _assertDeployedVault(vaultAddress, assetId, asset, tokenId, false);
    }

    function testDeployVaultWithLinkERC6909(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        uint256 tokenId = decimals;
        address asset = address(new MockERC6909());

        (uint128 assetId) = poolManager.registerAsset(OTHER_CHAIN_ID, asset, tokenId);
        address vaultAddress = poolManager.deployVault(poolId, scId, assetId, asyncVaultFactory);

        vm.expectEmit(true, true, true, false);
        emit IPoolManager.LinkVault(poolId, scId, asset, tokenId, vaultAddress);
        poolManager.linkVault(poolId, scId, assetId, vaultAddress);

        _assertDeployedVault(vaultAddress, assetId, asset, tokenId, true);
    }

    function testDeploVaultInvalidShare(uint64 poolId, bytes16 scId) public {
        vm.expectRevert(IPoolManager.ShareTokenDoesNotExist.selector);
        poolManager.deployVault(poolId, scId, defaultAssetId, asyncVaultFactory);
    }

    function testDeploVaultInvalidVaultFactory(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);

        vm.expectRevert(IPoolManager.InvalidFactory.selector);
        poolManager.deployVault(poolId, scId, defaultAssetId, address(0));
    }

    function testDeployVaultUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.deployVault(0, bytes16(0), 0, address(0));
    }
}

contract PoolManagerRegisterAssetTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;
    using BytesLib for *;

    uint32 constant STORAGE_INDEX_ASSET_COUNTER = 4;
    uint256 constant STORAGE_OFFSET_ASSET_COUNTER = 20;

    function _assertAssetCounterEq(uint32 expected) internal view {
        bytes32 slotData = vm.load(address(poolManager), bytes32(uint256(STORAGE_INDEX_ASSET_COUNTER)));

        // Extract `_assetCounter` at offset 20 bytes (rightmost 4 bytes)
        uint32 assetCounter = uint32(uint256(slotData >> (STORAGE_OFFSET_ASSET_COUNTER * 8)));
        assertEq(assetCounter, expected, "Asset counter does not match expected value");
    }

    function _assertAssetRegistered(address asset, uint128 assetId, uint256 tokenId, uint32 expectedAssetCounter)
        internal
        view
    {
        assertEq(poolManager.assetToId(asset, tokenId), assetId, "Asset to id mismatch");
        (address asset_, uint256 tokenId_) = poolManager.idToAsset(assetId);
        assertEq(asset_, asset);
        assertEq(tokenId_, tokenId);
        _assertAssetCounterEq(expectedAssetCounter);
    }

    function testRegisterSingleAssetERC20() public {
        address asset = address(erc20);
        bytes memory message =
            MessageLib.RegisterAsset({assetId: defaultAssetId, decimals: erc20.decimals()}).serialize();

        vm.expectEmit();
        emit IPoolManager.RegisterAsset(defaultAssetId, asset, 0, erc20.name(), erc20.symbol(), erc20.decimals());
        vm.expectEmit(false, false, false, false);
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), message);
        uint128 assetId = poolManager.registerAsset(OTHER_CHAIN_ID, asset, 0);

        assertEq(assetId, defaultAssetId);
        assertEq(erc20.allowance(address(poolManager.escrow()), address(poolManager)), type(uint256).max);
        _assertAssetRegistered(asset, assetId, 0, 1);
    }

    function testRegisterMultipleAssetsERC20(string calldata name, string calldata symbol, uint8 decimals) public {
        decimals = uint8(bound(decimals, 2, 18));

        ERC20 assetA = erc20;
        ERC20 assetB = _newErc20(name, symbol, decimals);

        uint128 assetIdA = poolManager.registerAsset(OTHER_CHAIN_ID, address(assetA), 0);
        _assertAssetRegistered(address(assetA), assetIdA, 0, 1);

        uint128 assetIdB = poolManager.registerAsset(OTHER_CHAIN_ID, address(assetB), 0);
        _assertAssetRegistered(address(assetB), assetIdB, 0, 2);

        assert(assetIdA != assetIdB);
    }

    function testRegisterSingleAssetERC20_emptyNameSymbol() public {
        ERC20 asset = _newErc20("", "", 10);
        poolManager.registerAsset(OTHER_CHAIN_ID, address(asset), 0);
        _assertAssetRegistered(address(asset), defaultAssetId, 0, 1);
    }

    function testRegisterSingleAssetERC6909(uint8 decimals) public {
        uint256 tokenId = uint256(bound(decimals, 2, 18));
        MockERC6909 erc6909 = new MockERC6909();
        address asset = address(erc6909);

        bytes memory message =
            MessageLib.RegisterAsset({assetId: defaultAssetId, decimals: erc6909.decimals(tokenId)}).serialize();

        vm.expectEmit();
        emit IPoolManager.RegisterAsset(
            defaultAssetId, asset, tokenId, erc6909.name(tokenId), erc6909.symbol(tokenId), erc6909.decimals(tokenId)
        );
        vm.expectEmit(false, false, false, false);
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), message);
        uint128 assetId = poolManager.registerAsset(OTHER_CHAIN_ID, asset, tokenId);

        assertEq(assetId, defaultAssetId);
        assertEq(erc6909.allowance(address(poolManager.escrow()), address(poolManager), tokenId), type(uint256).max);
        _assertAssetRegistered(asset, assetId, tokenId, 1);
    }

    function testRegisterMultipleAssetsERC6909(uint8 decimals) public {
        MockERC6909 erc6909 = new MockERC6909();
        uint256 tokenIdA = uint256(bound(decimals, 3, 18));
        uint256 tokenIdB = uint256(bound(decimals, 2, tokenIdA - 1));

        uint128 assetIdA = poolManager.registerAsset(OTHER_CHAIN_ID, address(erc6909), tokenIdA);
        _assertAssetRegistered(address(erc6909), assetIdA, tokenIdA, 1);

        uint128 assetIdB = poolManager.registerAsset(OTHER_CHAIN_ID, address(erc6909), tokenIdB);
        _assertAssetRegistered(address(erc6909), assetIdB, tokenIdB, 2);

        assert(assetIdA != assetIdB);
    }

    function testRegisterAssetTwice() public {
        vm.expectEmit();
        emit IPoolManager.RegisterAsset(
            defaultAssetId, address(erc20), 0, erc20.name(), erc20.symbol(), erc20.decimals()
        );
        vm.expectEmit(false, false, false, false);
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), bytes(""));
        emit IGateway.PrepareMessage(OTHER_CHAIN_ID, PoolId.wrap(0), bytes(""));
        poolManager.registerAsset(OTHER_CHAIN_ID, address(erc20), 0);
        poolManager.registerAsset(OTHER_CHAIN_ID, address(erc20), 0);
    }

    function testRegisterAsset_decimalsMissing() public {
        address asset = address(new MockERC6909());
        vm.expectRevert(IPoolManager.AssetMissingDecimals.selector);
        poolManager.registerAsset(OTHER_CHAIN_ID, asset, 0);
    }

    function testRegisterAsset_invalidContract(uint256 tokenId) public {
        vm.expectRevert(IPoolManager.AssetMissingDecimals.selector);
        poolManager.registerAsset(OTHER_CHAIN_ID, address(0), tokenId);
    }

    function testRegisterAssetERC20_decimalDeficit() public {
        ERC20 asset = _newErc20("", "", 1);
        vm.expectRevert(IPoolManager.TooFewDecimals.selector);
        poolManager.registerAsset(OTHER_CHAIN_ID, address(asset), 0);
    }

    function testRegisterAssetERC20_decimalExcess() public {
        ERC20 asset = _newErc20("", "", 19);
        vm.expectRevert(IPoolManager.TooManyDecimals.selector);
        poolManager.registerAsset(OTHER_CHAIN_ID, address(asset), 0);
    }

    function testRegisterAssetERC6909_decimalDeficit() public {
        MockERC6909 asset = new MockERC6909();
        vm.expectRevert(IPoolManager.TooFewDecimals.selector);
        poolManager.registerAsset(OTHER_CHAIN_ID, address(asset), 1);
    }

    function testRegisterAssetERC6909_decimalExcess() public {
        MockERC6909 asset = new MockERC6909();
        vm.expectRevert(IPoolManager.TooManyDecimals.selector);
        poolManager.registerAsset(OTHER_CHAIN_ID, address(asset), 19);
    }

    function testRegisterAsset_unauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.registerAsset(0, address(0), 0);
    }
}

contract UpdateContractMock is IUpdateContract {
    IUpdateContract immutable poolManager;

    constructor(address poolManager_) {
        poolManager = IUpdateContract(poolManager_);
    }

    function update(uint64 poolId, bytes16 scId, bytes calldata payload) public {
        poolManager.update(poolId, scId, payload);
    }
}

contract PoolManagerUpdateContract is BaseTest, PoolManagerTestHelper {
    using MessageLib for *;

    function testUpdateContractTargetThis(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(asyncVaultFactory);

        vm.expectEmit();
        emit IPoolManager.UpdateContract(poolId, scId, address(poolManager), vaultUpdate);
        poolManager.updateContract(poolId, scId, address(poolManager), vaultUpdate);
    }

    function testUpdateContractTargetUpdateContractMock(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(asyncVaultFactory);
        UpdateContractMock mock = new UpdateContractMock(address(poolManager));
        IAuth(address(poolManager)).rely(address(mock));

        vm.expectEmit();
        emit IPoolManager.UpdateContract(poolId, scId, address(mock), vaultUpdate);
        poolManager.updateContract(poolId, scId, address(mock), vaultUpdate);
    }

    function testUpdateContractInvalidVaultFactory(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(address(1));

        vm.expectRevert(IPoolManager.InvalidFactory.selector);
        poolManager.updateContract(poolId, scId, address(poolManager), vaultUpdate);
    }

    function testUpdateContractUnknownVault(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 scId_
    ) public {
        setUpPoolAndShare(poolId_, decimals_, tokenName_, tokenSymbol_, scId_);
        registerAssetErc20();
        bytes memory vaultUpdate = MessageLib.UpdateContractVaultUpdate({
            vaultOrFactory: bytes32("1"),
            assetId: assetIdErc20,
            kind: uint8(VaultUpdateKind.Link)
        }).serialize();

        vm.expectRevert(IPoolManager.UnknownVault.selector);
        poolManager.updateContract(poolId, scId, address(poolManager), vaultUpdate);
    }

    function testUpdateContractInvalidShare(uint64 poolId) public {
        poolManager.addPool(poolId);
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(asyncVaultFactory);

        vm.expectRevert(IPoolManager.ShareTokenDoesNotExist.selector);
        poolManager.updateContract(poolId, scId, address(poolManager), vaultUpdate);
    }

    function testUpdateContractUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.updateContract(0, bytes16(0), address(0), bytes(""));
    }

    function testUpdateUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.update(0, bytes16(0), bytes(""));
    }

    function _serializedUpdateContractNewVault(address vaultFactory_) internal view returns (bytes memory payload) {
        return MessageLib.UpdateContractVaultUpdate({
            vaultOrFactory: bytes32(bytes20(vaultFactory_)),
            assetId: assetIdErc20,
            kind: uint8(VaultUpdateKind.DeployAndLink)
        }).serialize();
    }
}
