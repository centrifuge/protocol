// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {IVaultFactory} from "../../src/core/spoke/factories/interfaces/IVaultFactory.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {IVault} from "../../src/vaults/interfaces/IVault.sol";
import {VaultFactory} from "../../src/vaults/factories/VaultFactory.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {PerPeriodPolicy, PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultDeployFactory} from "../../src/vaults/factories/interfaces/IVaultDeployFactory.sol";
import {IAsyncVault, IVaultErrors, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

/// @dev A vault's address depends on its plugins and its variant. It is deployed by anyone ahead of the hub's
///      deploy-and-link, which resolves that address through `getVault`. The property that matters is therefore
///      that preview and deploy agree, on every input and not just the default one.
contract VaultFactoryTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    address root = makeAddr("root");
    address spokeHandler = makeAddr("spokeHandler");
    address outsider = makeAddr("outsider");
    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address escrow = address(new IsContract());

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);

    VaultFactory factory;

    function setUp() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSignature("assetToId(address,uint256,bool)", address(asset), uint256(0), true),
            abi.encode(ASSET_ID)
        );
        vm.mockCall(spokeRegistry, abi.encodeCall(ISpokeRegistry.shareToken, (POOL, SC)), abi.encode(share));

        factory = new VaultFactory(root, ISpoke(spoke), ISpokeRegistry(spokeRegistry));
    }

    function _plugins(address oracle, address instantPolicy) internal returns (VaultPlugins memory) {
        return VaultPlugins({
            oracle: IVaultOracle(oracle),
            instantPolicy: IInstantPolicy(instantPolicy),
            requestPolicy: IRequestPolicy(address(new PerRequestPolicy(true))),
            liquidityRoute: ILiquidityRoute(address(0)),
            settlementObserver: ISettlementObserver(address(0))
        });
    }

    function _payload(VaultPlugins memory plugins, uint64 variant) internal pure returns (bytes memory) {
        return abi.encode(plugins, variant, uint256(0));
    }

    function _deploy(VaultPlugins memory plugins, uint64 variant) internal returns (address) {
        return factory.deploy(POOL, SC, address(asset), 0, _payload(plugins, variant));
    }

    function _preview(VaultPlugins memory plugins, uint64 variant) internal view returns (address) {
        return factory.getVault(POOL, SC, address(asset), 0, address(share), _payload(plugins, variant));
    }

    /// @dev The load-bearing property: whatever the hub resolves is what gets deployed.
    function testPreviewMatchesDeployment(address oracle, address instantPolicy, uint64 variant) public {
        VaultPlugins memory plugins = _plugins(oracle, instantPolicy);
        address predicted = _preview(plugins, variant);

        assertEq(_deploy(plugins, variant), predicted, "getVault and deployment agree");
    }

    /// @dev What deploying a vault costs, and what it will cost when the larger code size limit arrives. A vault is one
    ///      flat contract over the 24 KiB limit, so it can only deploy where that limit is raised: on Ethereum that is
    ///      EIP-7954 (64 KiB of code, 128 KiB of initcode), scheduled with EIP-8037, which charges 1,530 gas per byte of
    ///      deployed code as state gas. The transaction cap of EIP-7825 (2^24) then binds the execution gas only, so
    ///      the deployment fits it, but the whole cost must fit the block's gas limit as the one transaction it is. The
    ///      estimate below is the draft's schedule applied to what was measured: the code deposit and the account at
    ///      the new rates, the factory's own execution unchanged.
    function testDeploymentCostToday() public {
        uint256 codeBytes = type(Vault).creationCode.length;
        uint256 gasBefore = gasleft();
        address vault = _deploy(_plugins(address(0xAA), address(0xBB)), 0);
        uint256 used = gasBefore - gasleft();
        uint256 runtime = vault.code.length;

        // The limits the vault has to fit where it deploys
        assertLe(runtime, 65_536, "EIP-7954 code size limit");
        assertLe(codeBytes, 131_072, "EIP-7954 initcode size limit");
        assertLt(used, 16_777_216, "EIP-7825 transaction gas cap, on today's pricing");

        // EIP-8037 draft: CPSB 1,530 per deployed byte, 120 bytes of account state, 64 bytes per new storage slot
        uint256 executionToday = used - 200 * runtime - 32_000 - 20_000;
        uint256 estimate = 1_530 * runtime + 120 * 1_530 + 64 * 1_530 + executionToday + 6 * ((runtime + 31) / 32);
        console.log("vault runtime bytes", runtime);
        console.log("deploy gas today", used);
        console.log("deploy gas under EIP-8037 draft", estimate);
        assertLt(estimate, 150_000_000, "one vault deployment must fit a 150M block with room to spare");
    }

    /// @dev Parallel vaults on one position are exactly what the variant salt is for.
    function testVariantsDeployInParallel() public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), address(0));

        address first = _deploy(plugins, 0);
        address second = _deploy(plugins, 1);

        assertNotEq(first, second, "same position, different variant, different vault");
        assertEq(IVault(first).poolId().raw(), POOL.raw());
        assertEq(IVault(second).poolId().raw(), POOL.raw());
    }

    /// @dev Whoever deploys second gets the first one's vault, which is the same configuration.
    function testDeployingTwiceReturnsTheSameVault() public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), address(0));
        vm.prank(outsider);
        address first = _deploy(plugins, 7);

        assertEq(_deploy(plugins, 7), first);
        assertEq(IAuth(first).wards(root), 1, "root is still the vault's ward");
    }

    /// @dev Policies are part of the address, so two vaults differing only in a policy do not collide
    ///      under the same variant either.
    function testPluginsChangeTheAddress() public {
        address a = _preview(_plugins(makeAddr("oracleA"), address(0)), 0);
        address b = _preview(_plugins(makeAddr("oracleB"), address(0)), 0);

        assertNotEq(a, b);
    }

    /// @dev Anyone may deploy: the address commits to the configuration the hub later links.
    function testDeploymentIsPermissionless() public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), address(0));

        vm.prank(outsider);
        assertEq(_deploy(plugins, 0), _preview(plugins, 0));
    }

    /// @dev The event carries the whole identity and configuration, so an indexer reads the vault from it alone.
    function testDeployingEmitsTheVaultsWholeIdentity() public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), makeAddr("instantPolicy"));
        address predicted = _preview(plugins, 3);

        vm.expectEmit(true, true, true, true, address(factory));
        emit IVaultDeployFactory.VaultDeployed(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            predicted,
            address(share),
            escrow,
            ISpoke(spoke),
            ISpokeRegistry(spokeRegistry),
            IVaultDeployFactory.Payload(plugins, 3, 0),
            1
        );
        _deploy(plugins, 3);
    }

    /// @dev A configured horizon is part of the address, and the event reports it as the vault applies it.
    function testTheHorizonIsPartOfTheAddressAndTheEvent() public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), address(0));
        bytes memory payload = abi.encode(plugins, uint64(0), uint256(2));
        address predicted = factory.getVault(POOL, SC, address(asset), 0, address(share), payload);
        assertNotEq(predicted, _preview(plugins, 0), "a horizon is a different vault");

        vm.expectEmit(true, true, true, true, address(factory));
        emit IVaultDeployFactory.VaultDeployed(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            predicted,
            address(share),
            escrow,
            ISpoke(spoke),
            ISpokeRegistry(spokeRegistry),
            IVaultDeployFactory.Payload(plugins, 0, 2),
            2
        );
        factory.deploy(POOL, SC, address(asset), 0, payload);
        assertEq(IAsyncVault(predicted).foldHorizon(), 2);
    }

    /// @dev A configuration the vault refuses is named by the factory, not reported as a bare deployment failure.
    function testAHorizonTheVaultRefusesIsNamed() public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), address(0));
        plugins.requestPolicy = new PerPeriodPolicy(1 days, 0, 0, 4 days);
        bytes memory payload = abi.encode(plugins, uint64(0), uint256(2));
        vm.expectRevert(IVaultErrors.InvalidFoldHorizon.selector);
        factory.deploy(POOL, SC, address(asset), 0, payload);
    }

    /// @dev A policy reporting no open buckets is refused whatever the horizon: it would leave no slot for a controller's
    ///      own request, and a zero default horizon would leave none at all.
    function testAPolicyWithNoOpenBucketsIsRefused(uint256 horizon) public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), address(0));
        vm.mockCall(
            address(plugins.requestPolicy), abi.encodeCall(IRequestPolicy.maxOpenBuckets, ()), abi.encode(uint256(0))
        );
        vm.expectRevert(IVaultErrors.InvalidFoldHorizon.selector);
        factory.deploy(POOL, SC, address(asset), 0, abi.encode(plugins, uint64(0), horizon));
    }

    function testDeployingAnExistingVaultEmitsNothing() public {
        VaultPlugins memory plugins = _plugins(makeAddr("oracle"), address(0));
        _deploy(plugins, 3);

        vm.recordLogs();
        _deploy(plugins, 3);
        assertEq(vm.getRecordedLogs().length, 0, "nothing was deployed, nothing is announced");
    }

    function testDeployedVaultIsHandedOver() public {
        vm.prank(outsider);
        address vault = _deploy(_plugins(makeAddr("oracle"), address(0)), 0);

        assertEq(IAuth(vault).wards(root), 1, "root can act on the vault");
        assertEq(IAuth(vault).wards(outsider), 0, "the deployer keeps nothing");
        assertEq(IAuth(vault).wards(spokeHandler), 0, "the spoke handler links it without being a ward");
        assertEq(IAuth(vault).wards(address(factory)), 0, "the factory keeps nothing");
    }

    function testNonZeroTokenIdUnsupported() public {
        bytes memory payload = _payload(_plugins(makeAddr("oracle"), address(0)), 0);

        vm.expectRevert(IVaultFactory.UnsupportedTokenId.selector);
        factory.deploy(POOL, SC, address(asset), 1, payload);
    }

    /// @dev The vault reads its share token and the pool's escrow, so the share class has to be on the spoke.
    function testDeploymentNeedsTheShareClass() public {
        ShareClassId unknown = ShareClassId.wrap(bytes16("sc2"));
        vm.mockCall(spokeRegistry, abi.encodeCall(ISpokeRegistry.shareToken, (POOL, unknown)), abi.encode(address(0)));
        bytes memory payload = _payload(_plugins(makeAddr("oracle"), address(0)), 0);

        vm.expectRevert(ISpokeRegistry.ShareTokenDoesNotExist.selector);
        factory.deploy(POOL, unknown, address(asset), 0, payload);
    }

    /// @dev The hub's `DeployAndLink` resolves the vault deployed ahead of it, and deploys nothing itself.
    function testNewVaultResolvesTheDeployedVault() public {
        bytes memory payload = _payload(_plugins(makeAddr("oracle"), address(0)), 3);
        address deployed = factory.deploy(POOL, SC, address(asset), 0, payload);

        vm.prank(spokeHandler);
        assertEq(factory.newVault(POOL, SC, address(asset), 0, address(share), payload), deployed);
    }

    /// @dev A message arriving first fails, and stays retryable until the vault is deployed.
    function testNewVaultRefusesBeforeDeployment() public {
        bytes memory payload = _payload(_plugins(makeAddr("oracle"), address(0)), 0);

        vm.prank(spokeHandler);
        vm.expectRevert(IVaultDeployFactory.VaultNotDeployed.selector);
        factory.newVault(POOL, SC, address(asset), 0, address(share), payload);
    }

    /// @dev `newVault` only reads: anyone gets the address `getVault` already gives them, so it asks no authority.
    function testNewVaultIsOpenToAnyone() public {
        bytes memory payload = _payload(_plugins(makeAddr("oracle"), address(0)), 0);
        address vault = factory.deploy(POOL, SC, address(asset), 0, payload);

        vm.prank(outsider);
        assertEq(factory.newVault(POOL, SC, address(asset), 0, address(share), payload), vault);
    }

    /// @dev A vault has no default plugins, so an empty payload names nothing to deploy.
    function testEmptyPayloadRefuses() public {
        vm.expectRevert(IVaultDeployFactory.PluginsRequired.selector);
        factory.deploy(POOL, SC, address(asset), 0, bytes(""));

        vm.expectRevert(IVaultDeployFactory.PluginsRequired.selector);
        factory.getVault(POOL, SC, address(asset), 0, address(share), bytes(""));
    }
}
