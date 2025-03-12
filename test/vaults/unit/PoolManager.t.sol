// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MockERC6909} from "test/misc/mocks/MockERC6909.sol";
import "test/vaults/BaseTest.sol";
import {MockHook} from "test/vaults/mocks/MockHook.sol";

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {MessageLib} from "src/common/libraries/MessageLib.sol";

import {IRestrictionManager} from "src/vaults/interfaces/token/IRestrictionManager.sol";
import {IPoolManager} from "src/vaults/interfaces/IPoolManager.sol";
import {IBaseVault, IVaultManager} from "src/vaults/interfaces/IVaultManager.sol";
import {IGateway} from "src/vaults/interfaces/gateway/IGateway.sol";

contract PoolManagerTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(nonWard != address(root) && nonWard != address(gateway) && nonWard != address(this));

        address[] memory vaultFactories = new address[](1);
        vaultFactories[0] = address(vaultFactory);

        // redeploying within test to increase coverage
        new PoolManager(address(escrow), trancheFactory, vaultFactories, uint32(block.chainid));

        // values set correctly
        assertEq(address(poolManager.gateway()), address(gateway));
        assertEq(address(poolManager.escrow()), address(escrow));
        assertEq(address(gateway.poolManager()), address(poolManager));
        assertEq(address(investmentManager.poolManager()), address(poolManager));

        // permissions set correctly
        assertEq(poolManager.wards(address(root)), 1);
        assertEq(poolManager.wards(address(gateway)), 1);
        assertEq(escrow.wards(address(poolManager)), 1);
        assertEq(poolManager.wards(nonWard), 0);
    }

    function testFile() public {
        address newGateway = makeAddr("newGateway");
        poolManager.file("gateway", newGateway);
        assertEq(address(poolManager.gateway()), newGateway);

        address newTrancheFactory = makeAddr("newTrancheFactory");
        poolManager.file("trancheFactory", newTrancheFactory);
        assertEq(address(poolManager.trancheFactory()), newTrancheFactory);

        address newVaultFactory = makeAddr("newVaultFactory");
        assertEq(poolManager.vaultFactory(newVaultFactory), false);
        poolManager.file("vaultFactory", newVaultFactory, true);
        assertEq(poolManager.vaultFactory(newVaultFactory), true);
        assertEq(poolManager.vaultFactory(vaultFactory), true);

        address newEscrow = makeAddr("newEscrow");
        vm.expectRevert("PoolManager/file-unrecognized-param");
        poolManager.file("escrow", newEscrow);
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(bytes("PoolManager/invalid-message"));
        poolManager.handle(1, abi.encodePacked(uint8(0)));
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

        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, salt, hook);
        Tranche tranche = Tranche(poolManager.getTranche(poolId, trancheId));
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
            Tranche tranche = Tranche(poolManager.getTranche(poolId, trancheIds[i]));
            assertEq(tokenName, tranche.name());
            assertEq(tokenSymbol, tranche.symbol());
            assertEq(decimals, tranche.decimals());
        }
    }

    function testDeployVaultWithoutLink(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());
        address asset = address(erc20);

        centrifugeChain.addPool(poolId);
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);

        // Check event except for vault address which cannot be known
        vm.expectEmit(true, true, true, false);
        emit IPoolManager.DeployVault(poolId, trancheId, asset, vaultFactory, address(0));
        address vaultAddress = poolManager.deployVault(poolId, trancheId, asset, vaultFactory);

        // Check Vault asset
        (address asset_, bool isWrapper) = poolManager.getVaultAsset(vaultAddress);
        assertEq(asset, asset_, "vault asset mismatch");
        assertEq(isWrapper, false);

        // Check Tranche permissions
        address tranche_ = poolManager.getTranche(poolId, trancheId);
        address vaultManager = IBaseVault(vaultAddress).manager();
        assertEq(Tranche(tranche_).wards(vaultManager), 1);

        // Check approvals
        console.log("vaultManager: ", vaultManager);
        assertEq(
            IERC20(asset).allowance(address(poolManager.escrow()), vaultManager),
            type(uint256).max,
            "Asset allowance missing"
        );
        assertEq(
            IERC20(tranche_).allowance(address(poolManager.escrow()), vaultManager),
            type(uint256).max,
            "Tranche token allowance missing"
        );

        // Check missing link
        address vault_ = ITranche(tranche_).vault(asset);
        assertEq(vault_, address(0), "Tranche link to vault requires linkVault");
        assertEq(investmentManager.wards(vaultAddress), 0, "Vault auth on investmentManager set up in linkVault");

        // Check tranche state
        Tranche tranche = Tranche(tranche_);
        assertEq(tranche.name(), tokenName, "tranche name mismatch");
        assertEq(tranche.symbol(), tokenSymbol, "tranche symbol mismatch");
        assertEq(tranche.decimals(), decimals, "tranche decimals mismatch");
        assertEq(tranche.wards(address(poolManager)), 1);
        assertEq(tranche.wards(address(this)), 0);
        assertEq(tranche.wards(vault_), 0, "Vault auth on Tranche set up in linkVault");
    }

    function testDeployVaultWithLink(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());
        address asset = address(erc20);

        centrifugeChain.addPool(poolId);
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);

        address vaultAddress = poolManager.deployVault(poolId, trancheId, asset, vaultFactory);
        poolManager.linkVault(poolId, trancheId, asset, vaultAddress);

        address tranche_ = poolManager.getTranche(poolId, trancheId);
        address vault_ = ITranche(tranche_).vault(asset);
        assertEq(vaultAddress, vault_);

        // check vault state
        ERC7540Vault vault = ERC7540Vault(vault_);
        Tranche tranche = Tranche(tranche_);
        assertEq(address(vault.manager()), address(investmentManager), "investment manager mismatch");
        assertEq(vault.asset(), asset, "asset mismatch");
        assertEq(vault.poolId(), poolId, "poolId mismatch");
        assertEq(vault.trancheId(), trancheId, "trancheId mismatch");
        assertEq(address(vault.share()), tranche_, "tranche mismatch");
        assertEq(vault.wards(address(investmentManager)), 1);
        assertEq(vault.wards(address(this)), 0);
        assertEq(investmentManager.wards(vaultAddress), 1);

        assertEq(tranche.name(), tokenName, "tranche name mismatch");
        assertEq(tranche.symbol(), tokenSymbol, "tranche symbol mismatch");
        assertEq(tranche.decimals(), decimals, "tranche decimals mismatch");

        assertEq(tranche.wards(address(poolManager)), 1);
        assertEq(tranche.wards(vault_), 1);
        assertEq(tranche.wards(address(this)), 0);
    }

    function testTransferTrancheTokensToCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        bytes32 centChainAddress = makeAddr("centChainAddress").toBytes32();
        (address vault_,) = deploySimpleVault();
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

    function testTransferTrancheTokensFromCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        (address vault_,) = deploySimpleVault();
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

        (address vault_,) = deploySimpleVault();
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
        poolManager.transferTrancheTokens(
            poolId + 1, trancheId, uint32(block.chainid), destinationAddress.toBytes32(), amount
        );

        // Approve and transfer amount from this address to destinationAddress
        tranche.approve(address(poolManager), amount);
        poolManager.transferTrancheTokens(
            vault.poolId(), vault.trancheId(), uint32(block.chainid), destinationAddress.toBytes32(), amount
        );
        assertEq(tranche.balanceOf(address(this)), 0);
    }

    function testUpdateMember(uint64 validUntil) public {
        validUntil = uint64(bound(validUntil, block.timestamp, type(uint64).max));
        (address vault_,) = deploySimpleVault();
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
        (address vault_,) = deploySimpleVault();
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
        (address vault_,) = deploySimpleVault();
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
        (address vault_,) = deploySimpleVault();
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
        (address vault_,) = deploySimpleVault();
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

    function testAllowAsset() public {
        uint64 poolId = 1;
        uint128 assetId = poolManager.registerAsset(address(erc20), 0, 0);

        centrifugeChain.addPool(poolId);

        centrifugeChain.allowAsset(poolId, assetId);
        assertTrue(poolManager.isAllowedAsset(poolId, address(erc20)));

        centrifugeChain.disallowAsset(poolId, assetId);
        assertEq(poolManager.isAllowedAsset(poolId, address(erc20)), false);

        uint128 randomCurrency = 100;

        vm.expectRevert(bytes("PoolManager/unknown-asset"));
        centrifugeChain.allowAsset(poolId, randomCurrency);

        vm.expectRevert(bytes("PoolManager/invalid-pool"));
        centrifugeChain.allowAsset(poolId + 1, randomCurrency);

        vm.expectRevert(bytes("PoolManager/unknown-asset"));
        centrifugeChain.disallowAsset(poolId, randomCurrency);

        vm.expectRevert(bytes("PoolManager/invalid-pool"));
        centrifugeChain.disallowAsset(poolId + 1, randomCurrency);
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
        uint128 assetId = poolManager.registerAsset(address(erc20), 0, 0);

        address hook = address(new MockHook());

        vm.expectRevert(bytes("PoolManager/tranche-does-not-exist"));
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp));

        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);
        centrifugeChain.allowAsset(poolId, assetId);

        // Allows us to go back in time later
        vm.warp(block.timestamp + 1 days);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp));

        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp));
        (uint256 latestPrice, uint64 priceComputedAt) = poolManager.getTranchePrice(poolId, trancheId, address(erc20));
        assertEq(latestPrice, price);
        assertEq(priceComputedAt, block.timestamp);

        vm.expectRevert(bytes("PoolManager/cannot-set-older-price"));
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp - 1));
    }

    function testVaultMigration() public {
        (address oldVault_, uint128 assetId) = deploySimpleVault();

        ERC7540Vault oldVault = ERC7540Vault(oldVault_);
        uint64 poolId = oldVault.poolId();
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
        assertEq(Tranche(poolManager.getTranche(poolId, trancheId)).vault(asset), address(0));

        // Deploy new vault
        address newVault = poolManager.deployVault(poolId, trancheId, asset, address(newVaultFactory));
        assert(oldVault_ != newVault);
    }

    function testPoolManagerCannotTransferTrancheTokensOnAccountRestrictions(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        (address vault_,) = deploySimpleVault();
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
        poolManager.transferTrancheTokens(
            poolId, trancheId, uint32(block.chainid), destinationAddress.toBytes32(), amount
        );
        assertEq(tranche.balanceOf(address(this)), amount);

        centrifugeChain.unfreeze(poolId, trancheId, address(this));
        poolManager.transferTrancheTokens(
            poolId, trancheId, uint32(block.chainid), destinationAddress.toBytes32(), amount
        );
        assertEq(tranche.balanceOf(address(escrow)), 0);
    }

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
}

contract PoolManagerRegisterAssetTest is BaseTest {
    using MessageLib for *;
    using CastLib for *;
    using BytesLib for *;

    uint32 constant STORAGE_INDEX_ASSET_COUNTER = 2;
    uint256 constant STORAGE_OFFSET_ASSET_COUNTER = 20;

    function _assertAssetCounterEq(uint32 expected) internal view {
        bytes32 slotData = vm.load(address(poolManager), bytes32(uint256(STORAGE_INDEX_ASSET_COUNTER)));

        // Extract `_assetCounter` at offset 20 bytes (rightmost 4 bytes)
        uint32 assetCounter = uint32(uint256(slotData >> (STORAGE_OFFSET_ASSET_COUNTER * 8)));

        // Verify the loaded value matches the expected value
        assertEq(assetCounter, expected, "Asset counter does not match expected value");
    }

    function _assertAssetRegistered(address asset, uint128 assetId, uint32 expectedAssetCounter) internal view {
        assertEq(poolManager.assetToId(asset), assetId);
        assertEq(poolManager.idToAsset(assetId), asset);
        _assertAssetCounterEq(expectedAssetCounter);
    }

    function testRegisterAssetERC20() public {
        address asset = address(erc20);
        console.log("AssetId: ", defaultAssetId);
        bytes memory message = MessageLib.RegisterAsset({
            assetId: defaultAssetId,
            name: erc20.name(),
            symbol: erc20.symbol().toBytes32(),
            decimals: erc20.decimals()
        }).serialize();

        vm.expectEmit();
        emit IGateway.SendMessage(message);
        emit IPoolManager.RegisterAsset(defaultAssetId, asset, 0, erc20.name(), erc20.symbol(), erc20.decimals());
        uint128 assetId = poolManager.registerAsset(asset, 0, defaultChainId);

        assertEq(assetId, defaultAssetId);
        assertEq(erc20.allowance(address(poolManager.escrow()), address(poolManager)), type(uint256).max);
        _assertAssetRegistered(asset, assetId, 1);
    }
}
