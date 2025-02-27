// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";

import "test/vaults/BaseTest.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IRestrictionManager} from "src/vaults/interfaces/token/IRestrictionManager.sol";
import {MockHook} from "test/vaults/mocks/MockHook.sol";
import {RestrictionUpdate} from "src/vaults/interfaces/token/IRestrictionManager.sol";

contract PoolManagerTest is BaseTest {
    using CastLib for *;

    // Deployment
    function testDeployment(address nonWard) public {
        vm.assume(nonWard != address(root) && nonWard != address(gateway) && nonWard != address(this));

        // redeploying within test to increase coverage
        new PoolManager(address(escrow), vaultFactory, trancheFactory);

        // values set correctly
        assertEq(address(poolManager.gateway()), address(gateway));
        assertEq(address(poolManager.escrow()), address(escrow));
        assertEq(address(poolManager.investmentManager()), address(investmentManager));
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

        address newInvestmentManager = makeAddr("newInvestmentManager");
        poolManager.file("investmentManager", newInvestmentManager);
        assertEq(address(poolManager.investmentManager()), newInvestmentManager);

        address newTrancheFactory = makeAddr("newTrancheFactory");
        poolManager.file("trancheFactory", newTrancheFactory);
        assertEq(address(poolManager.trancheFactory()), newTrancheFactory);

        address newVaultFactory = makeAddr("newVaultFactory");
        poolManager.file("vaultFactory", newVaultFactory);
        assertEq(address(poolManager.vaultFactory()), newVaultFactory);

        address newEscrow = makeAddr("newEscrow");
        vm.expectRevert("PoolManager/file-unrecognized-param");
        poolManager.file("escrow", newEscrow);
    }

    function testHandleInvalidMessage() public {
        vm.expectRevert(bytes("PoolManager/invalid-message"));
        poolManager.handle(abi.encodePacked(uint8(MessagesLib.Call.Invalid)));
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
        uint8 decimals
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());

        vm.expectRevert(bytes("PoolManager/invalid-pool"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);
        centrifugeChain.addPool(poolId);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        vm.prank(randomUser);
        poolManager.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);

        vm.expectRevert(bytes("PoolManager/too-few-tranche-token-decimals"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, 0, hook);

        vm.expectRevert(bytes("PoolManager/too-many-tranche-token-decimals"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, 19, hook);

        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);
        assertTrue(poolManager.canTrancheBeDeployed(poolId, trancheId));

        vm.expectRevert(bytes("PoolManager/tranche-already-exists"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);

        poolManager.deployTranche(poolId, trancheId);
        assertFalse(poolManager.canTrancheBeDeployed(poolId, trancheId));

        Tranche tranche = Tranche(poolManager.getTranche(poolId, trancheId));

        assertEq(tokenName, tranche.name());
        assertEq(tokenSymbol, tranche.symbol());
        assertEq(decimals, tranche.decimals());
        assertEq(hook, tranche.hook());

        vm.expectRevert(bytes("PoolManager/tranche-already-deployed"));
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);
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
            poolManager.deployTranche(poolId, trancheIds[i]);
            Tranche tranche = Tranche(poolManager.getTranche(poolId, trancheIds[i]));
            assertEq(tokenName, tranche.name());
            assertEq(tokenSymbol, tranche.symbol());
            assertEq(decimals, tranche.decimals());
        }
    }

    function testDeployTranche(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 assetId
    ) public {
        vm.assume(assetId > 0);
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());

        centrifugeChain.addPool(poolId); // add pool

        vm.expectRevert(bytes("PoolManager/tranche-not-added"));
        poolManager.deployTranche(poolId, trancheId);
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook); // add tranche
        address tranche_ = poolManager.deployTranche(poolId, trancheId);
        Tranche tranche = Tranche(tranche_);
        assertEq(tranche.wards(address(root)), 1);
        assertEq(tranche.wards(address(investmentManager)), 1);
        assertEq(tokenName, tranche.name());
        assertEq(tokenSymbol, tranche.symbol());
    }

    function testAddAsset(uint128 assetId) public {
        uint128 badCurrency = 2;
        vm.assume(assetId > 0);
        vm.assume(assetId != badCurrency);
        ERC20 erc20_invalid_too_few = _newErc20("X's Dollar", "USDX", 0);
        ERC20 erc20_invalid_too_many = _newErc20("X's Dollar", "USDX", 42);

        vm.expectRevert(bytes("PoolManager/too-few-asset-decimals"));
        centrifugeChain.addAsset(assetId, address(erc20_invalid_too_few));

        vm.expectRevert(bytes("PoolManager/too-many-asset-decimals"));
        centrifugeChain.addAsset(assetId, address(erc20_invalid_too_many));

        vm.expectRevert(bytes("PoolManager/asset-id-has-to-be-greater-than-0"));
        centrifugeChain.addAsset(0, address(erc20));

        centrifugeChain.addAsset(assetId, address(erc20));

        // Verify we can't override the same asset id another address
        vm.expectRevert(bytes("PoolManager/asset-id-in-use"));
        centrifugeChain.addAsset(assetId, makeAddr("randomCurrency"));

        // Verify we can't add a asset address that already exists associated with a different aset id
        vm.expectRevert(bytes("PoolManager/asset-address-in-use"));
        centrifugeChain.addAsset(badCurrency, address(erc20));

        assertEq(poolManager.idToAsset(assetId), address(erc20));
    }

    function testDeployVault(
        uint64 poolId,
        uint8 decimals,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 assetId
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(assetId > 0);
        vm.assume(bytes(tokenName).length <= 128);
        vm.assume(bytes(tokenSymbol).length <= 32);

        address hook = address(new MockHook());

        centrifugeChain.addPool(poolId); // add pool
        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook); // add tranche
        centrifugeChain.addAsset(assetId, address(erc20));

        vm.expectRevert(bytes("PoolManager/tranche-does-not-exist"));
        poolManager.deployVault(poolId, trancheId, address(erc20));
        address tranche_ = poolManager.deployTranche(poolId, trancheId);

        vm.expectRevert(bytes("PoolManager/asset-not-supported"));
        poolManager.deployVault(poolId, trancheId, address(erc20));
        centrifugeChain.allowAsset(poolId, assetId);

        address vaultAddress = poolManager.deployVault(poolId, trancheId, address(erc20));
        address vault_ = poolManager.getVault(poolId, trancheId, address(erc20));

        vm.expectRevert(bytes("PoolManager/vault-already-deployed"));
        poolManager.deployVault(poolId, trancheId, address(erc20));

        // make sure the pool was added to the tranche struct
        assertEq(vaultAddress, vault_);

        // check vault state
        ERC7540Vault vault = ERC7540Vault(vault_);
        Tranche tranche = Tranche(tranche_);
        assertEq(address(vault.manager()), address(investmentManager));
        assertEq(vault.asset(), address(erc20));
        assertEq(vault.poolId(), poolId);
        assertEq(vault.trancheId(), trancheId);
        assertEq(address(vault.share()), tranche_);
        assertTrue(vault.wards(address(investmentManager)) == 1);
        assertTrue(vault.wards(address(this)) == 0);
        assertTrue(investmentManager.wards(vaultAddress) == 1);

        // assertEq(tranche.name(), tokenName);
        // assertEq(tranche.symbol(), tokenSymbol);
        assertEq(tranche.decimals(), decimals);

        assertTrue(tranche.wards(address(poolManager)) == 1);
        assertTrue(tranche.wards(vault_) == 1);
        assertTrue(tranche.wards(address(this)) == 0);
    }

    function testTransferTrancheTokensToCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        bytes32 centChainAddress = makeAddr("centChainAddress").toBytes32();
        address vault_ = deploySimpleVault();
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
        bytes memory message =
            abi.encodePacked(uint8(MessagesLib.Call.TransferTrancheTokens), poolId, trancheId, centChainAddress, amount);
        assertEq(adapter1.sent(message), 1);
    }

    function testTransferTrancheTokensFromCentrifuge(uint128 amount) public {
        vm.assume(amount > 0);
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        address vault_ = deploySimpleVault();
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

        address vault_ = deploySimpleVault();
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
            poolId + 1, trancheId, uint64(block.chainid), destinationAddress.toBytes32(), amount
        );

        // Approve and transfer amount from this address to destinationAddress
        tranche.approve(address(poolManager), amount);
        poolManager.transferTrancheTokens(
            vault.poolId(), vault.trancheId(), uint64(block.chainid), destinationAddress.toBytes32(), amount
        );
        assertEq(tranche.balanceOf(address(this)), 0);
    }

    function testUpdateMember(uint64 validUntil) public {
        validUntil = uint64(bound(validUntil, block.timestamp, type(uint64).max));
        address vault_ = deploySimpleVault();
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
        address vault_ = deploySimpleVault();
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
        address vault_ = deploySimpleVault();
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
        address vault_ = deploySimpleVault();
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
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        ITranche tranche = ITranche(address(ERC7540Vault(vault_).share()));

        bytes memory update = abi.encodePacked(uint8(RestrictionUpdate.Freeze), makeAddr("User").toBytes32());

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
        uint128 assetId = defaultAssetId;
        uint64 poolId = 1;

        centrifugeChain.addAsset(assetId, address(erc20));
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
        uint128 assetId,
        string memory tokenName,
        string memory tokenSymbol,
        bytes16 trancheId,
        uint128 price
    ) public {
        decimals = uint8(bound(decimals, 2, 18));
        vm.assume(poolId > 0);
        vm.assume(trancheId > 0);
        vm.assume(assetId > 0);
        centrifugeChain.addPool(poolId);

        address hook = address(new MockHook());

        vm.expectRevert(bytes("PoolManager/tranche-does-not-exist"));
        centrifugeChain.updateTranchePrice(poolId, trancheId, assetId, price, uint64(block.timestamp));

        centrifugeChain.addTranche(poolId, trancheId, tokenName, tokenSymbol, decimals, hook);
        centrifugeChain.addAsset(assetId, address(erc20));
        centrifugeChain.allowAsset(poolId, assetId);

        poolManager.deployTranche(poolId, trancheId);

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

    function testRemoveVault() public {
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        address asset = address(vault.asset());
        address tranche_ = address(vault.share());
        Tranche tranche = Tranche(tranche_);

        poolManager.deny(address(this));
        vm.expectRevert(IAuth.NotAuthorized.selector);
        poolManager.removeVault(poolId, trancheId, asset);

        root.relyContract(address(poolManager), address(this));

        vm.expectRevert(bytes("PoolManager/tranche-does-not-exist"));
        poolManager.removeVault(poolId, bytes16(0), asset);

        poolManager.removeVault(poolId, trancheId, asset);

        vm.expectRevert(bytes("PoolManager/vault-not-deployed"));
        poolManager.removeVault(poolId, trancheId, asset);

        vm.expectRevert(bytes("PoolManager/unknown-vault"));
        poolManager.getVault(poolId, trancheId, asset);
        assertEq(investmentManager.wards(vault_), 0);
        assertEq(tranche.wards(vault_), 0);
        assertEq(tranche.allowance(address(escrow), vault_), 0);

        vm.expectRevert(bytes("PoolManager/unknown-vault"));
        poolManager.getVaultAsset(vault_);
    }

    function testRemoveVaultFailsWhenVaultNotDeployed() public {
        uint64 poolId = 5;
        bytes16 trancheId = bytes16(bytes("1"));

        address hook = address(new MockHook());

        centrifugeChain.addPool(poolId); // add pool
        centrifugeChain.addTranche(poolId, trancheId, "Test Token", "TT", 6, hook); // add tranche

        centrifugeChain.addAsset(10, address(erc20));
        centrifugeChain.allowAsset(poolId, 10);
        poolManager.deployTranche(poolId, trancheId);

        vm.expectRevert(bytes("PoolManager/vault-not-deployed"));
        poolManager.removeVault(poolId, trancheId, address(erc20));
    }

    function testVaultMigration() public {
        address oldVault_ = deploySimpleVault();

        ERC7540Vault oldVault = ERC7540Vault(oldVault_);
        uint64 poolId = oldVault.poolId();
        bytes16 trancheId = oldVault.trancheId();
        address asset = address(oldVault.asset());

        ERC7540VaultFactory newVaultFactory = new ERC7540VaultFactory(address(root));

        // rewire factory contracts
        newVaultFactory.rely(address(poolManager));
        investmentManager.rely(address(newVaultFactory));
        poolManager.file("vaultFactory", address(newVaultFactory));

        // Remove old vault
        poolManager.removeVault(poolId, trancheId, asset);
        vm.expectRevert(bytes("PoolManager/unknown-vault"));
        poolManager.getVault(poolId, trancheId, asset);

        // Deploy new vault
        address newVault = poolManager.deployVault(poolId, trancheId, asset);
        assertEq(poolManager.getVault(poolId, trancheId, asset), newVault);
    }

    function testGetVaultByAssetId() public {
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        address asset = address(vault.asset());
        uint128 assetId = poolManager.assetToId(asset);

        assertEq(poolManager.getVault(poolId, trancheId, assetId), vault_);
    }

    function testGetVaultByAsset() public {
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        address asset = address(vault.asset());

        assertEq(poolManager.getVault(poolId, trancheId, asset), vault_);
    }

    function testGetInvalidVaultByAssetIdFails() public {
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        vm.expectRevert(bytes("PoolManager/unknown-vault"));
        poolManager.getVault(poolId, trancheId, defaultAssetId + 1);
    }

    function testGetInvalidVaultByAssetFails() public {
        address vault_ = deploySimpleVault();
        ERC7540Vault vault = ERC7540Vault(vault_);
        uint64 poolId = vault.poolId();
        bytes16 trancheId = vault.trancheId();
        vm.expectRevert(bytes("PoolManager/unknown-vault"));
        poolManager.getVault(poolId, trancheId, address(1));
    }

    function testPoolManagerCannotTransferTrancheTokensOnAccountRestrictions(uint128 amount) public {
        uint64 validUntil = uint64(block.timestamp + 7 days);
        address destinationAddress = makeAddr("destinationAddress");
        vm.assume(amount > 0);

        address vault_ = deploySimpleVault();
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
            poolId, trancheId, uint64(block.chainid), destinationAddress.toBytes32(), amount
        );
        assertEq(tranche.balanceOf(address(this)), amount);

        centrifugeChain.unfreeze(poolId, trancheId, address(this));
        poolManager.transferTrancheTokens(
            poolId, trancheId, uint64(block.chainid), destinationAddress.toBytes32(), amount
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
