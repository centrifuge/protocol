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

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {IRestrictionManager} from "src/vaults/interfaces/token/IRestrictionManager.sol";
import {IPoolManager, VaultDetails} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseVault, IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IUpdateContract} from "src/vaults/interfaces/IUpdateContract.sol";

contract PoolManagerTestHelper is BaseTest {
    uint64 poolId;
    uint8 decimals;
    string tokenName;
    string tokenSymbol;
    bytes16 trancheId;
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

    function setUpPoolAndTranche(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        decimals_ = uint8(bound(decimals_, 2, 18));
        vm.assume(bytes(tokenName_).length <= 128);
        vm.assume(bytes(tokenSymbol_).length <= 32);

        poolId = poolId_;
        decimals = decimals_;
        tokenName = tokenName;
        tokenSymbol = tokenSymbol_;
        trancheId = trancheId_;

        centrifugeChain.addPool(poolId);
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, address(new MockHook()));
    }

    function registerAssetErc20() public {
        assetErc20 = address(_newErc20(tokenName, tokenSymbol, decimals));
        assetIdErc20 = poolManager.registerAsset(assetErc20, 0, OTHER_CHAIN_ID);
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
        );

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = address(vaultFactory);

        // redeploying within test to increase coverage
        new PoolManager(address(escrow), trancheFactory, vaultFactories);

        // values set correctly
        assertEq(address(poolManager.escrow()), address(escrow));
        assertEq(address(investmentManager.poolManager()), address(poolManager));

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

        address newTrancheFactory = makeAddr("newTrancheFactory");
        vm.expectEmit();
        emit IPoolManager.File("trancheFactory", newTrancheFactory);
        poolManager.file("trancheFactory", newTrancheFactory);
        assertEq(address(poolManager.trancheFactory()), newTrancheFactory);

        address newVaultFactory = makeAddr("newVaultFactory");
        assertEq(poolManager.vaultFactory(newVaultFactory), false);
        poolManager.file("vaultFactory", newVaultFactory, true);
        assertEq(poolManager.vaultFactory(newVaultFactory), true);
        assertEq(poolManager.vaultFactory(vaultFactory), true);

        vm.expectEmit();
        emit IPoolManager.File("vaultFactory", newVaultFactory, false);
        poolManager.file("vaultFactory", newVaultFactory, false);
        assertEq(poolManager.vaultFactory(newVaultFactory), false);

        address newEscrow = makeAddr("newEscrow");
        vm.expectRevert("PoolManager/file-unrecognized-param");
        poolManager.file("escrow", newEscrow);

        vm.expectRevert("PoolManager/file-unrecognized-param");
        poolManager.file("escrow", newEscrow, true);

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.file("", address(0));

        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.file("", address(0), true);
    }

    function testRecoverTokensERC20(uint256 amount) public {
        vm.assume(amount > 0);

        address asset = address(erc20);
        address to = makeAddr("to");
        erc20.mint(address(poolManager), amount);

        assertEq(erc20.balanceOf(to), 0);
        poolManager.recoverTokens(asset, 0, to, amount);
        assertEq(erc20.balanceOf(address(poolManager)), 0);
        assertEq(erc20.balanceOf(to), amount);
    }

    function testRecoverTokensERC6909(uint256 amount, uint8 tokenId) public {
        vm.assume(amount > 0);
        tokenId = uint8(bound(tokenId, 2, 18));

        MockERC6909 erc6909 = new MockERC6909();
        address asset = address(erc6909);
        address to = makeAddr("to");
        erc6909.mint(address(poolManager), tokenId, amount);

        assertEq(erc6909.balanceOf(to, tokenId), 0);
        poolManager.recoverTokens(asset, tokenId, to, amount);
        assertEq(erc6909.balanceOf(address(poolManager), tokenId), 0);
        assertEq(erc6909.balanceOf(to, tokenId), amount);
    }

    function testRecoverTokensUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.recoverTokens(address(0), 0, address(0), 0);
    }

    function testAddPool(uint64 poolId) public {
        centrifugeChain.addPool(poolId);

        vm.expectRevert(bytes("PoolManager/pool-already-added"));
        centrifugeChain.addPool(poolId);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.addPool(poolId);
    }

    function testAddTranche(
        uint64 poolId,
        bytes16 trancheId,
        string memory tokenName,
        string memory tokenSymbol,
        bytes32 salt,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());

        vm.expectRevert(bytes("PoolManager/invalid-pool"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, salt, hook);
        centrifugeChain.addPool(poolId);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, salt, hook);

        vm.expectRevert(bytes("PoolManager/too-few-tranche-token-decimals"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, 0, hook);

        vm.expectRevert(bytes("PoolManager/too-many-tranche-token-decimals"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, 19, hook);

        vm.expectRevert(bytes("PoolManager/invalid-hook"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, salt, address(1));

        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, salt, hook);
        Tranche tranche = Tranche(poolManager.tranche(poolId, trancheId));
        assertEq(tokenName, tranche.name());
        assertEq(tokenSymbol, tranche.symbol());
        assertEq(decimals, tranche.decimals());
        assertEq(hook, tranche.hook());

        vm.expectRevert(bytes("PoolManager/tranche-already-exists"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, salt, hook);
    }

    function testAddMultipleTranchesWorks(
        uint64 poolId,
        bytes16[4] calldata trancheIds,
        string memory tokenName,
        string memory tokenSymbol,
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(!hasDuplicates(trancheIds));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        centrifugeChain.addPool(poolId);

        address hook = address(new MockHook());

        for (uint256 i = 0; i < trancheIds.length; i++) {
            centrifugeChain.addTranche(poolId, trancheIds[i], tokenName, tokenSymbol, decimals, hook);
            Tranche tranche = Tranche(poolManager.tranche(poolId, trancheIds[i]));
            assertEq(tokenName, tranche.name());
            assertEq(tokenSymbol, tranche.symbol());
            assertEq(decimals, tranche.decimals());
        }
    }

    function testTransferTrancheTokensToCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        bytes32 centChainAddress = makeAddr("centChainAddress").toBytes32();
        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));

        // fund this account with amount
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(this), validUntil);

        centrifugeChain.incomingTransferTrancheTokens(vault.poolId(), vault.trancheId(), address(this), amount);
        assertEq(tranche.balanceOf(address(this)), amount); // Verify the address(this) has the expected amount

        // fails for invalid tranche token
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        vm.expectRevert(bytes("PoolManager/unknown-token"));
        poolManager.transferTrancheTokens(poolId + 1, trancheId, 0, centChainAddress, amount);

        // send the transfer from EVM -> Cent Chain
        tranche.approve(address(poolManager), amount);
        poolManager.transferTrancheTokens(poolId, trancheId, 0, centChainAddress, amount);
        assertEq(tranche.balanceOf(address(this)), 0);

        // Finally, verify the connector called `adapter.send`
        bytes memory message = MessageLib.TransferShares(poolId, trancheId, centChainAddress, amount).serialize();
        assertEq(adapter1.sent(message), 1);
    }

    function testTransferTrancheTokensUnauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.transferTrancheTokens(0, bytes16(0), 0, 0, 0);
    }

    function testTransferTrancheTokensFromCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();

        ITranche tranche = ITranche(address(vault.share()));

        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        centrifugeChain.incomingTransferTrancheTokens(poolId, trancheId, destinationAddress, amount);
        centrifugeChain.updateMember(poolId, trancheId, destinationAddress, validUntil);

        vm.expectRevert(bytes("PoolManager/unknown-token"));
        centrifugeChain.incomingTransferTrancheTokens(poolId + 1, trancheId, destinationAddress, amount);

        assertTrue(tranche.checkTransferRestriction(address(0), destinationAddress, 0));
        centrifugeChain.incomingTransferTrancheTokens(poolId, trancheId, destinationAddress, amount);
        assertEq(tranche.balanceOf(destinationAddress), amount);
    }

    function testTransferTrancheTokensToEVM(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), destinationAddress, validUntil);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(this), validUntil);
        assertTrue(tranche.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(tranche.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with samount
        centrifugeChain.incomingTransferTrancheTokens(vault.poolId(), vault.trancheId(), address(this), amount);
        assertEq(tranche.balanceOf(address(this)), amount);

        // fails for invalid tranche token
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        vm.expectRevert(bytes("PoolManager/unknown-token"));
        poolManager.transferTrancheTokens(poolId + 1, trancheId, OTHER_CHAIN_ID, destinationAddress.toBytes32(), amount);

        // Approve and transfer amount from this address to destinationAddress
        tranche.approve(address(poolManager), amount);
        poolManager.transferTrancheTokens(
            vault.poolId(), vault.trancheId(), OTHER_CHAIN_ID, destinationAddress.toBytes32(), amount
        );
        assertEq(tranche.balanceOf(address(this)), 0);
    }

    function testUpdateMember(uint64 validUntil) public {
        validUntil = uint64(bound(validUntil, block.timestamp, type(uint64).max));
        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));

        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        IRestrictionManager hook = IRestrictionManager(tranche.hook());
        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        hook.updateMember(address(tranche), randomUser, validUntil);

        vm.expectRevert(bytes("PoolManager/unknown-token"));
        centrifugeChain.updateMember(100, bytes16(bytes("100")), randomUser, validUntil); // use random poolId &
            // trancheId

        centrifugeChain.updateMember(poolId, trancheId, randomUser, validUntil);
        assertTrue(tranche.checkTransferRestriction(address(0), randomUser, 0));

        vm.expectRevert(bytes("RestrictionManager/endorsed-user-cannot-be-updated"));
        centrifugeChain.updateMember(poolId, trancheId, address(escrow), validUntil);
    }

    function testFreezeAndUnfreeze() public {
        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address secondUser = makeAddr("secondUser");

        vm.expectRevert(bytes("RestrictionManager/endorsed-user-cannot-be-frozen"));
        centrifugeChain.freeze(poolId, trancheId, address(escrow));

        vm.expectRevert(bytes("PoolManager/unknown-token"));
        centrifugeChain.freeze(poolId + 1, trancheId, randomUser);

        vm.expectRevert(bytes("PoolManager/unknown-token"));
        centrifugeChain.unfreeze(poolId + 1, trancheId, randomUser);

        centrifugeChain.updateMember(poolId, trancheId, randomUser, validUntil);
        centrifugeChain.updateMember(poolId, trancheId, secondUser, validUntil);
        assertTrue(tranche.checkTransferRestriction(randomUser, secondUser, 0));

        centrifugeChain.freeze(poolId, trancheId, randomUser);
        assertFalse(tranche.checkTransferRestriction(randomUser, secondUser, 0));

        centrifugeChain.unfreeze(poolId, trancheId, randomUser);
        assertTrue(tranche.checkTransferRestriction(randomUser, secondUser, 0));

        centrifugeChain.freeze(poolId, trancheId, secondUser);
        assertFalse(tranche.checkTransferRestriction(randomUser, secondUser, 0));

        centrifugeChain.unfreeze(poolId, trancheId, secondUser);
        assertTrue(tranche.checkTransferRestriction(randomUser, secondUser, 0));
    }

    function testUpdateTrancheMetadata() public {
        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));

        string memory updatedTokenName = "newName";
        string memory updatedTokenSymbol = "newSymbol";

        vm.expectRevert(bytes("PoolManager/unknown-token"));
        centrifugeChain.updateTrancheMetadata(100, bytes16(bytes("100")), updatedTokenName, updatedTokenSymbol);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateTrancheMetadata(poolId, trancheId, updatedTokenName, updatedTokenSymbol);

        assertEq(tranche.name(), "name");
        assertEq(tranche.symbol(), "symbol");

        centrifugeChain.updateTrancheMetadata(poolId, trancheId, updatedTokenName, updatedTokenSymbol);
        assertEq(tranche.name(), updatedTokenName);
        assertEq(tranche.symbol(), updatedTokenSymbol);

        vm.expectRevert(bytes("PoolManager/old-metadata"));
        centrifugeChain.updateTrancheMetadata(poolId, trancheId, updatedTokenName, updatedTokenSymbol);
    }

    function testUpdateTrancheHook() public {
        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));

        address newHook = makeAddr("NewHook");

        vm.expectRevert(bytes("PoolManager/unknown-token"));
        centrifugeChain.updateTrancheHook(100, bytes16(bytes("100")), newHook);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateTrancheHook(poolId, trancheId, newHook);

        assertEq(tranche.hook(), restrictionManager);

        centrifugeChain.updateTrancheHook(poolId, trancheId, newHook);
        assertEq(tranche.hook(), newHook);

        vm.expectRevert(bytes("PoolManager/old-hook"));
        centrifugeChain.updateTrancheHook(poolId, trancheId, newHook);
    }

    function testUpdateRestriction() public {
        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));

        bytes memory update = MessageLib.UpdateRestrictionFreeze(makeAddr("User").toBytes32()).serialize();

        vm.expectRevert(bytes("PoolManager/unknown-token"));
        poolManager.updateRestriction(100, bytes16(bytes("100")), update);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateRestriction(poolId, trancheId, update);

        address hook = tranche.hook();
        poolManager.updateTrancheHook(poolId, trancheId, address(0));

        vm.expectRevert(bytes("PoolManager/invalid-hook"));
        poolManager.updateRestriction(poolId, trancheId, update);

        poolManager.updateTrancheHook(poolId, trancheId, hook);

        poolManager.updateRestriction(poolId, trancheId, update);
    }

    function testUpdateTranchePriceWorks(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 price
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(poolId > 0);
        vm.assume(trancheId > 0);
        centrifugeChain.addPool(poolId);
        uint128 assetId = poolManager.registerAsset(address(erc20), 0, OTHER_CHAIN_ID);

        address hook = address(new MockHook());

        vm.expectRevert(bytes("PoolManager/tranche-does-not-exist"));
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp));

        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);

        vm.expectRevert("PoolManager/unknown-price");
        poolManager.tranchePrice(poolId, trancheId, assetId);

        // Allows us to go back in time later
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp));

        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp));
        (uint256 latestPrice, uint64 priceComputedAt) = poolManager.tranchePrice(poolId, trancheId, assetId);
        assertEq(latestPrice, price);
        assertEq(priceComputedAt, block.timestamp);

        vm.expectRevert(bytes("PoolManager/cannot-set-older-price"));
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp - 1));
    }

    function testVaultMigration() public {
        (uint64 poolId, address oldVault_, uint128 assetId) = deploySimpleVault();

        ERC7540Vault oldVault = ERC7540Vault(oldVault_);
        bytes16 trancheId = oldVault.trancheId();
        address asset = address(oldVault.asset());

        ERC7540VaultFactory newVaultFactory = new ERC7540VaultFactory(address(root), address(investmentManager));

        // rewire factory contracts
        newVaultFactory.rely(address(poolManager));
        investmentManager.rely(address(newVaultFactory));
        poolManager.file("vaultFactory", address(newVaultFactory), true);

        // Remove old vault
        address vaultManager = IBaseVault(oldVault_).manager();
        IVaultManager(vaultManager).removeVault(poolId, trancheId, oldVault_, asset, assetId);
        assertEq(Tranche(poolManager.tranche(poolId, trancheId)).vault(asset), address(0));

        // Deploy new vault
        address newVault = poolManager.deployVault(poolId, trancheId, assetId, address(newVaultFactory));
        assert(oldVault_ != newVault);
    }

    function testPoolManagerCannotTransferTrancheTokensOnAccountRestrictions(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (, address vault_,) = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));
        tranche.approve(address(poolManager), amount);

        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), destinationAddress, validUntil);
        centrifugeChain.updateMember(vault.poolId(), vault.trancheId(), address(this), validUntil);
        assertTrue(tranche.checkTransferRestriction(address(0), address(this), 0));
        assertTrue(tranche.checkTransferRestriction(address(0), destinationAddress, 0));

        // Fund this address with amount
        centrifugeChain.incomingTransferTrancheTokens(vault.poolId(), vault.trancheId(), address(this), amount);
        assertEq(tranche.balanceOf(address(this)), amount);

        // fails for invalid tranche token
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();

        centrifugeChain.freeze(poolId, trancheId, address(this));
        assertFalse(tranche.checkTransferRestriction(address(this), destinationAddress, 0));

        vm.expectRevert(bytes("RestrictionManager/transfer-blocked"));
        poolManager.transferTrancheTokens(poolId, trancheId, OTHER_CHAIN_ID, destinationAddress.toBytes32(), amount);
        assertEq(tranche.balanceOf(address(this)), amount);

        centrifugeChain.unfreeze(poolId, trancheId, address(this));
        poolManager.transferTrancheTokens(poolId, trancheId, OTHER_CHAIN_ID, destinationAddress.toBytes32(), amount);
        assertEq(tranche.balanceOf(address(escrow)), 0);
    }

    function testLinkVaultInvalidTranche(uint64 poolId, bytes16 trancheId) public {
        vm.expectRevert("PoolManager/tranche-does-not-exist");
        poolManager.linkVault(poolId, trancheId, defaultAssetId, address(0));
    }

    function testUnlinkVaultInvalidTranche(uint64 poolId, bytes16 trancheId) public {
        vm.expectRevert("PoolManager/tranche-does-not-exist");
        poolManager.unlinkVault(poolId, trancheId, defaultAssetId, address(0));
    }

    function testLinkVaultUnauthorized(uint64 poolId, bytes16 trancheId) public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.linkVault(poolId, trancheId, defaultAssetId, address(0));
    }

    function testUnlinkVaultUnauthorized(uint64 poolId, bytes16 trancheId) public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.unlinkVault(poolId, trancheId, defaultAssetId, address(0));
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
        address vaultManager = IBaseVault(vaultAddress).manager();
        address tranche_ = poolManager.tranche(poolId, trancheId);
        address vault_ = ITranche(tranche_).vault(asset);

        assert(poolManager.isPoolActive(poolId));

        VaultDetails memory vaultDetails = poolManager.vaultDetails(vaultAddress);
        assertEq(assetId, vaultDetails.assetId, "vault assetId mismatch");
        assertEq(asset, vaultDetails.asset, "vault asset mismatch");
        assertEq(tokenId, vaultDetails.tokenId, "vault asset mismatch");
        assertEq(false, vaultDetails.isWrapper, "vault isWrapper mismatch");
        assertEq(isLinked, vaultDetails.isLinked, "vault isLinked mismatch");

        if (isLinked) {
            assert(poolManager.isLinked(poolId, trancheId, asset, vaultAddress));

            // check vault state
            assertEq(vaultAddress, vault_, "vault address mismatch");
            ERC7540Vault vault = ERC7540Vault(vault_);
            assertEq(address(vault.manager()), address(investmentManager), "investment manager mismatch");
            assertEq(vault.asset(), asset, "asset mismatch");
            assertEq(vault.poolId(), poolId, "poolId mismatch");
            assertEq(vault.trancheId(), trancheId, "trancheId mismatch");
            assertEq(address(vault.share()), tranche_, "tranche mismatch");

            assertEq(vault.wards(address(investmentManager)), 1);
            assertEq(vault.wards(address(this)), 0);
            assertEq(investmentManager.wards(vaultAddress), 1);
        } else {
            assert(!poolManager.isLinked(poolId, trancheId, asset, vaultAddress));
            // Check Tranche permissions
            assertEq(Tranche(tranche_).wards(vaultManager), 1);

            // Check missing link
            assertEq(vault_, address(0), "Tranche link to vault requires linkVault");
            assertEq(investmentManager.wards(vaultAddress), 0, "Vault auth on investmentManager set up in linkVault");
        }
    }

    function _assertTrancheSetup(address vaultAddress, bool isLinked) private view {
        address tranche_ = poolManager.tranche(poolId, trancheId);
        Tranche tranche = Tranche(tranche_);

        assertEq(tranche.wards(address(poolManager)), 1);
        assertEq(tranche.wards(address(this)), 0);

        assertEq(tranche.name(), tokenName, "tranche name mismatch");
        assertEq(tranche.symbol(), tokenSymbol, "tranche symbol mismatch");
        assertEq(tranche.decimals(), decimals, "tranche decimals mismatch");

        if (isLinked) {
            assertEq(tranche.wards(vaultAddress), 1);
        } else {
            assertEq(tranche.wards(vaultAddress), 0, "Vault auth on Tranche set up in linkVault");
        }
    }

    function _assertAllowance(address vaultAddress, address asset, uint256 tokenId) private view {
        address vaultManager = IBaseVault(vaultAddress).manager();
        address escrow_ = address(poolManager.escrow());
        address tranche_ = poolManager.tranche(poolId, trancheId);

        assertEq(
            IERC20(tranche_).allowance(escrow_, vaultManager), type(uint256).max, "Tranche token allowance missing"
        );

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
        _assertTrancheSetup(vaultAddress, isLinked);
        _assertAllowance(vaultAddress, asset, tokenId);
    }

    function testDeployVaultWithoutLinkERC20(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);

        address asset = address(erc20);

        // Check event except for vault address which cannot be known
        (uint128 assetId) = poolManager.registerAsset(asset, erc20TokenId, OTHER_CHAIN_ID);
        vm.expectEmit(true, true, true, false);
        emit IPoolManager.DeployVault(poolId, trancheId, asset, erc20TokenId, vaultFactory, address(0));
        address vaultAddress = poolManager.deployVault(poolId, trancheId, assetId, vaultFactory);

        _assertDeployedVault(vaultAddress, assetId, asset, erc20TokenId, false);
    }

    function testDeployVaultWithLinkERC20(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);

        address asset = address(erc20);

        (uint128 assetId) = poolManager.registerAsset(asset, erc20TokenId, OTHER_CHAIN_ID);
        address vaultAddress = poolManager.deployVault(poolId, trancheId, assetId, vaultFactory);

        vm.expectEmit(true, true, true, false);
        emit IPoolManager.LinkVault(poolId, trancheId, asset, erc20TokenId, vaultAddress);
        poolManager.linkVault(poolId, trancheId, assetId, vaultAddress);

        _assertDeployedVault(vaultAddress, assetId, asset, erc20TokenId, true);
    }

    function testDeployVaultWithoutLinkERC6909(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);

        uint256 tokenId = decimals;
        address asset = address(new MockERC6909());

        // Check event except for vault address which cannot be known
        (uint128 assetId) = poolManager.registerAsset(asset, tokenId, OTHER_CHAIN_ID);
        vm.expectEmit(true, true, true, false);
        emit IPoolManager.DeployVault(poolId, trancheId, asset, tokenId, vaultFactory, address(0));
        address vaultAddress = poolManager.deployVault(poolId, trancheId, assetId, vaultFactory);

        _assertDeployedVault(vaultAddress, assetId, asset, tokenId, false);
    }

    function testDeployVaultWithLinkERC6909(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);

        uint256 tokenId = decimals;
        address asset = address(new MockERC6909());

        (uint128 assetId) = poolManager.registerAsset(asset, tokenId, OTHER_CHAIN_ID);
        address vaultAddress = poolManager.deployVault(poolId, trancheId, assetId, vaultFactory);

        vm.expectEmit(true, true, true, false);
        emit IPoolManager.LinkVault(poolId, trancheId, asset, tokenId, vaultAddress);
        poolManager.linkVault(poolId, trancheId, assetId, vaultAddress);

        _assertDeployedVault(vaultAddress, assetId, asset, tokenId, true);
    }

    function testDeploVaultInvalidTranche(uint64 poolId, bytes16 trancheId) public {
        vm.expectRevert("PoolManager/tranche-does-not-exist");
        poolManager.deployVault(poolId, trancheId, defaultAssetId, vaultFactory);
    }

    function testDeploVaultInvalidVaultFactory(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);

        vm.expectRevert("PoolManager/invalid-factory");
        poolManager.deployVault(poolId, trancheId, defaultAssetId, address(0));
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

    uint32 constant STORAGE_INDEX_ASSET_COUNTER = 3;
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
        bytes memory message = MessageLib.RegisterAsset({
            assetId: defaultAssetId,
            name: erc20.name(),
            symbol: erc20.symbol().toBytes32(),
            decimals: erc20.decimals()
        }).serialize();

        vm.expectEmit();
        emit IPoolManager.RegisterAsset(defaultAssetId, asset, 0, erc20.name(), erc20.symbol(), erc20.decimals());
        vm.expectEmit(false, false, false, false);
        emit IGateway.SendMessage(message);
        uint128 assetId = poolManager.registerAsset(asset, 0, OTHER_CHAIN_ID);

        assertEq(assetId, defaultAssetId);
        assertEq(erc20.allowance(address(poolManager.escrow()), address(poolManager)), type(uint256).max);
        _assertAssetRegistered(asset, assetId, 0, 1);
    }

    function testRegisterMultipleAssetsERC20(string calldata name, string calldata symbol, uint8 decimals) public {
        decimals = uint8(bound(decimals, 2, 18));

        ERC20 assetA = erc20;
        ERC20 assetB = _newErc20(name, symbol, decimals);

        uint128 assetIdA = poolManager.registerAsset(address(assetA), 0, OTHER_CHAIN_ID);
        _assertAssetRegistered(address(assetA), assetIdA, 0, 1);

        uint128 assetIdB = poolManager.registerAsset(address(assetB), 0, OTHER_CHAIN_ID);
        _assertAssetRegistered(address(assetB), assetIdB, 0, 2);

        assert(assetIdA != assetIdB);
    }

    function testRegisterSingleAssetERC20_emptyNameSymbol() public {
        ERC20 asset = _newErc20("", "", 10);
        poolManager.registerAsset(address(asset), 0, OTHER_CHAIN_ID);
        _assertAssetRegistered(address(asset), defaultAssetId, 0, 1);
    }

    function testRegisterSingleAssetERC6909(uint8 decimals) public {
        uint256 tokenId = uint256(bound(decimals, 2, 18));
        MockERC6909 erc6909 = new MockERC6909();
        address asset = address(erc6909);

        bytes memory message = MessageLib.RegisterAsset({
            assetId: defaultAssetId,
            name: erc6909.name(tokenId),
            symbol: erc6909.symbol(tokenId).toBytes32(),
            decimals: erc6909.decimals(tokenId)
        }).serialize();

        vm.expectEmit();
        emit IPoolManager.RegisterAsset(
            defaultAssetId, asset, tokenId, erc6909.name(tokenId), erc6909.symbol(tokenId), erc6909.decimals(tokenId)
        );
        vm.expectEmit(false, false, false, false);
        emit IGateway.SendMessage(message);
        uint128 assetId = poolManager.registerAsset(asset, tokenId, OTHER_CHAIN_ID);

        assertEq(assetId, defaultAssetId);
        assertEq(erc6909.allowance(address(poolManager.escrow()), address(poolManager), tokenId), type(uint256).max);
        _assertAssetRegistered(asset, assetId, tokenId, 1);
    }

    function testRegisterMultipleAssetsERC6909(uint8 decimals) public {
        MockERC6909 erc6909 = new MockERC6909();
        uint256 tokenIdA = uint256(bound(decimals, 3, 18));
        uint256 tokenIdB = uint256(bound(decimals, 2, tokenIdA - 1));

        uint128 assetIdA = poolManager.registerAsset(address(erc6909), tokenIdA, OTHER_CHAIN_ID);
        _assertAssetRegistered(address(erc6909), assetIdA, tokenIdA, 1);

        uint128 assetIdB = poolManager.registerAsset(address(erc6909), tokenIdB, OTHER_CHAIN_ID);
        _assertAssetRegistered(address(erc6909), assetIdB, tokenIdB, 2);

        assert(assetIdA != assetIdB);
    }

    function testRegisterAssetTwice() public {
        vm.expectEmit();
        emit IPoolManager.RegisterAsset(
            defaultAssetId, address(erc20), 0, erc20.name(), erc20.symbol(), erc20.decimals()
        );
        vm.expectEmit(false, false, false, false);
        emit IGateway.SendMessage(bytes(""));
        emit IGateway.SendMessage(bytes(""));
        poolManager.registerAsset(address(erc20), 0, OTHER_CHAIN_ID);
        poolManager.registerAsset(address(erc20), 0, OTHER_CHAIN_ID + 1);
    }

    function testRegisterAsset_decimalsMissing() public {
        address asset = address(new MockERC6909());
        vm.expectRevert("PoolManager/asset-missing-decimals");
        poolManager.registerAsset(asset, 0, OTHER_CHAIN_ID);
    }

    function testRegisterAsset_invalidContract(uint256 tokenId) public {
        vm.expectRevert("PoolManager/asset-missing-decimals");
        poolManager.registerAsset(address(0), tokenId, OTHER_CHAIN_ID);
    }

    function testRegisterAssetERC20_decimalDeficit() public {
        ERC20 asset = _newErc20("", "", 1);
        vm.expectRevert("PoolManager/too-few-asset-decimals");
        poolManager.registerAsset(address(asset), 0, OTHER_CHAIN_ID);
    }

    function testRegisterAssetERC20_decimalExcess() public {
        ERC20 asset = _newErc20("", "", 19);
        vm.expectRevert("PoolManager/too-many-asset-decimals");
        poolManager.registerAsset(address(asset), 0, OTHER_CHAIN_ID);
    }

    function testRegisterAssetERC6909_decimalDeficit() public {
        MockERC6909 asset = new MockERC6909();
        vm.expectRevert("PoolManager/too-few-asset-decimals");
        poolManager.registerAsset(address(asset), 1, OTHER_CHAIN_ID);
    }

    function testRegisterAssetERC6909_decimalExcess() public {
        MockERC6909 asset = new MockERC6909();
        vm.expectRevert("PoolManager/too-many-asset-decimals");
        poolManager.registerAsset(address(asset), 19, OTHER_CHAIN_ID);
    }

    function testRegisterAsset_unauthorized() public {
        vm.prank(makeAddr("unauthorized"));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.registerAsset(address(0), 0, 0);
    }
}

contract UpdateContractMock is IUpdateContract {
    IUpdateContract immutable poolManager;

    constructor(address poolManager_) {
        poolManager = IUpdateContract(poolManager_);
    }

    function update(uint64 poolId, bytes16 trancheId, bytes calldata payload) public {
        poolManager.update(poolId, trancheId, payload);
    }
}

contract PoolManagerUpdateContract is BaseTest, PoolManagerTestHelper {
    using MessageLib for *;

    function testUpdateContractTargetThis(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(vaultFactory);

        vm.expectEmit();
        emit IPoolManager.UpdateContract(poolId, trancheId, address(poolManager), vaultUpdate);
        poolManager.updateContract(poolId, trancheId, address(poolManager), vaultUpdate);
    }

    function testUpdateContractTargetUpdateContractMock(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(vaultFactory);
        UpdateContractMock mock = new UpdateContractMock(address(poolManager));
        IAuth(address(poolManager)).rely(address(mock));

        vm.expectEmit();
        emit IPoolManager.UpdateContract(poolId, trancheId, address(mock), vaultUpdate);
        poolManager.updateContract(poolId, trancheId, address(mock), vaultUpdate);
    }

    function testUpdateContractInvalidVaultFactory(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);
        registerAssetErc20();
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(address(1));

        vm.expectRevert("PoolManager/invalid-factory");
        poolManager.updateContract(poolId, trancheId, address(poolManager), vaultUpdate);
    }

    function testUpdateContractUnknownVault(
        uint64 poolId_,
        uint8 decimals_,
        string memory tokenName_,
        string memory tokenSymbol_,
        bytes16 trancheId_
    ) public {
        setUpPoolAndTranche(poolId_, decimals_, tokenName_, tokenSymbol_, trancheId_);
        registerAssetErc20();
        bytes memory vaultUpdate = MessageLib.UpdateContractVaultUpdate({
            vaultOrFactory: bytes32("1"),
            assetId: assetIdErc20,
            kind: uint8(VaultUpdateKind.Link)
        }).serialize();

        vm.expectRevert("PoolManager/unknown-vault");
        poolManager.updateContract(poolId, trancheId, address(poolManager), vaultUpdate);
    }

    function testUpdateContractInvalidTranche(uint64 poolId) public {
        centrifugeChain.addPool(poolId);
        bytes memory vaultUpdate = _serializedUpdateContractNewVault(vaultFactory);

        vm.expectRevert("PoolManager/tranche-does-not-exist");
        poolManager.updateContract(poolId, trancheId, address(poolManager), vaultUpdate);
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
