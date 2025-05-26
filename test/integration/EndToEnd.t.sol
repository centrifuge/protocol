// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {ERC20} from "src/misc/ERC20.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {Guardian} from "src/common/Guardian.sol";
import {Root} from "src/common/Root.sol";
import {Gateway} from "src/common/Gateway.sol";
import {MessageLib, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {Hub} from "src/hub/Hub.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

import {VaultRouter} from "src/spoke/vaults/VaultRouter.sol";
import {Spoke} from "src/spoke/Spoke.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {AsyncRequestManager} from "src/spoke/vaults/AsyncRequestManager.sol";
import {SyncRequestManager} from "src/spoke/vaults/SyncRequestManager.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IAsyncVault} from "src/spoke/interfaces/IBaseVaults.sol";
import {SyncDepositVault} from "src/spoke/vaults/SyncDepositVault.sol";
import {AsyncVaultFactory} from "src/spoke/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/spoke/factories/SyncDepositVaultFactory.sol";

import {FullDeployer, HubDeployer, SpokeDeployer} from "script/FullDeployer.s.sol";
import {CommonDeployer, MESSAGE_COST_ENV} from "script/CommonDeployer.s.sol";

import {LocalAdapter} from "test/integration/adapters/LocalAdapter.sol";

/// README
/// This EndToEnd tests emulates two chains fully deployed and connected through an adapter
/// Each test case can receive a fuzzed boolean parameter to be tested in both cases:
/// - If sameChain: HUB is in CENTRIFUGE_ID_A and CV is in CENTRIFUGE_ID_A
/// - If !sameChain: HUB is in CENTRIFUGE_ID_A and CV is in CENTRIFUGE_ID_B
///
/// NOTE: All contracts used needs to be placed in the below structs to avoid external calls each time a contract is
/// chosen from a deployment. If not, it has two side effects:
///   1.
///   vm.prank(FM)
///   deployA.hub().notifyPool() // Will fail, given prank is used to retriver the hub.
///
///   2. It increases significatily the amount of calls shown by the debugger.
///
/// By using these structs we avoid both "issues".

struct CHub {
    uint16 centrifugeId;
    // Common
    Root root;
    Guardian guardian;
    Gateway gateway;
    // Hub
    HubRegistry hubRegistry;
    Accounting accounting;
    Holdings holdings;
    ShareClassManager shareClassManager;
    Hub hub;
    IdentityValuation identityValuation;
}

struct CSpoke {
    uint16 centrifugeId;
    // Common
    Root root;
    Guardian guardian;
    Gateway gateway;
    // Vaults
    BalanceSheet balanceSheet;
    Spoke spoke;
    VaultRouter router;
    AsyncVaultFactory asyncVaultFactory;
    SyncDepositVaultFactory syncDepositVaultFactory;
    // Hooks
    address fullRestrictionsHook;
    address redemptionRestrictionsHook;
}

/// End to end testing assuming two full deployments in two different chains
contract TestEndToEnd is Test {
    using CastLib for *;
    using MessageLib for *;

    ISafe immutable safeAdminA = ISafe(makeAddr("SafeAdminA"));
    ISafe immutable safeAdminB = ISafe(makeAddr("SafeAdminB"));

    uint16 constant CENTRIFUGE_ID_A = 5;
    uint16 constant CENTRIFUGE_ID_B = 6;
    uint64 constant GAS = 10 wei;
    uint256 constant DEFAULT_SUBSIDY = 100 ether;

    address immutable FM = makeAddr("FM");
    address immutable INVESTOR_A = makeAddr("INVESTOR_A");
    address immutable ANY = makeAddr("ANY");

    uint128 constant INVESTOR_A_AMOUNT = 1_000_000e6;

    AccountId constant ASSET_ACCOUNT = AccountId.wrap(0x01);
    AccountId constant EQUITY_ACCOUNT = AccountId.wrap(0x02);
    AccountId constant LOSS_ACCOUNT = AccountId.wrap(0x03);
    AccountId constant GAIN_ACCOUNT = AccountId.wrap(0x04);

    FullDeployer deployA = new FullDeployer();
    FullDeployer deployB = new FullDeployer();

    AssetId USD = deployA.USD();
    CHub h;
    CSpoke s;

    D18 immutable IDENTITY_PRICE = d18(1, 1);

    function setUp() public {
        vm.setEnv(MESSAGE_COST_ENV, vm.toString(GAS));

        LocalAdapter adapterA = _deployChain(deployA, CENTRIFUGE_ID_A, CENTRIFUGE_ID_B, safeAdminA);
        LocalAdapter adapterB = _deployChain(deployB, CENTRIFUGE_ID_B, CENTRIFUGE_ID_A, safeAdminB);

        // We connect both deploys through the adapters
        adapterA.setEndpoint(adapterB);
        adapterB.setEndpoint(adapterA);

        // Initialize accounts
        vm.deal(FM, 1 ether);
        vm.deal(INVESTOR_A, 1 ether);
        vm.deal(ANY, 1 ether);

        // We not use the VM chain
        vm.chainId(0xDEAD);

        h = CHub({
            centrifugeId: CENTRIFUGE_ID_A,
            root: deployA.root(),
            guardian: deployA.guardian(),
            gateway: deployA.gateway(),
            hubRegistry: deployA.hubRegistry(),
            accounting: deployA.accounting(),
            holdings: deployA.holdings(),
            shareClassManager: deployA.shareClassManager(),
            hub: deployA.hub(),
            identityValuation: deployA.identityValuation()
        });
    }

    function _deployChain(FullDeployer deploy, uint16 localCentrifugeId, uint16 remoteCentrifugeId, ISafe safeAdmin)
        internal
        returns (LocalAdapter adapter)
    {
        deploy.deployFull(localCentrifugeId, safeAdmin, address(deploy), true);

        adapter = new LocalAdapter(localCentrifugeId, deploy.multiAdapter(), address(deploy));
        deploy.wire(remoteCentrifugeId, adapter, address(deploy));

        deploy.removeFullDeployerAccess(address(deploy));
    }

    function _setSpoke(bool sameChain) internal {
        FullDeployer deploy = (sameChain) ? deployA : deployB;
        uint16 centrifugeId = (sameChain) ? CENTRIFUGE_ID_A : CENTRIFUGE_ID_B;
        s = CSpoke({
            centrifugeId: centrifugeId,
            root: deploy.root(),
            guardian: deploy.guardian(),
            gateway: deploy.gateway(),
            balanceSheet: deploy.balanceSheet(),
            spoke: deploy.spoke(),
            router: deploy.vaultRouter(),
            fullRestrictionsHook: deploy.fullRestrictionsHook(),
            redemptionRestrictionsHook: deploy.redemptionRestrictionsHook(),
            asyncVaultFactory: deploy.asyncVaultFactory(),
            syncDepositVaultFactory: deploy.syncDepositVaultFactory()
        });
    }

    function _configurePool(address vaultFactory)
        internal
        returns (PoolId poolId, ShareClassId scId, AssetId assetId)
    {
        // Register AssetId

        ERC20 asset = new ERC20(6);
        asset.file("name", "USD Coin");
        asset.file("symbol", "USDC");
        asset.mint(INVESTOR_A, INVESTOR_A_AMOUNT);

        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(asset), 0);
        assetId = newAssetId(s.centrifugeId, 1);

        // Configure Pool
        poolId = h.hubRegistry.poolId(h.centrifugeId, 1);

        vm.startPrank(address(h.guardian.safe()));
        h.guardian.createPool(poolId, FM, USD);

        scId = h.shareClassManager.previewNextShareClassId(poolId);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(poolId, bytes("Testing pool"));
        h.hub.addShareClass(poolId, "Tokenized MMF", "MMF", bytes32("salt"));
        h.hub.notifyPool{value: GAS}(poolId, s.centrifugeId);
        h.hub.notifyShareClass{value: GAS}(poolId, scId, s.centrifugeId, s.redemptionRestrictionsHook.toBytes32());

        h.hub.createAccount(poolId, ASSET_ACCOUNT, true);
        h.hub.createAccount(poolId, EQUITY_ACCOUNT, false);
        h.hub.createAccount(poolId, LOSS_ACCOUNT, false);
        h.hub.createAccount(poolId, GAIN_ACCOUNT, false);
        h.hub.initializeHolding(
            poolId, scId, assetId, h.identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );

        h.hub.updatePricePerShare(poolId, scId, IDENTITY_PRICE);
        h.hub.notifySharePrice{value: GAS}(poolId, scId, s.centrifugeId);
        h.hub.notifyAssetPrice{value: GAS}(poolId, scId, assetId);
        h.hub.updateVault{value: GAS}(poolId, scId, assetId, vaultFactory.toBytes32(), VaultUpdateKind.DeployAndLink);

        vm.stopPrank();
        vm.deal(address(this), DEFAULT_SUBSIDY);
        s.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(poolId);
    }

    /// forge-config: default.isolate = true
    function testAsyncDeposit(bool sameChain) public {
        _setSpoke(sameChain);
        (PoolId poolId, ShareClassId scId, AssetId assetId) = _configurePool(address(s.asyncVaultFactory));

        IShareToken shareToken = IShareToken(s.spoke.shareToken(poolId, scId));
        (address asset,) = s.spoke.idToAsset(assetId);
        IAsyncVault vault = IAsyncVault(shareToken.vault(address(asset)));

        vm.startPrank(INVESTOR_A);
        ERC20(asset).approve(address(vault), INVESTOR_A_AMOUNT);
        vault.requestDeposit(INVESTOR_A_AMOUNT, INVESTOR_A, INVESTOR_A);

        vm.startPrank(FM);
        uint32 depositEpochId = h.hub.shareClassManager().nowDepositEpoch(scId, assetId);
        h.hub.approveDeposits{value: GAS}(poolId, scId, assetId, depositEpochId, INVESTOR_A_AMOUNT);
        h.hub.issueShares{value: GAS}(poolId, scId, assetId, depositEpochId, IDENTITY_PRICE);

        vm.startPrank(ANY);
        uint32 maxClaims = h.shareClassManager.maxDepositClaims(scId, INVESTOR_A.toBytes32(), assetId);
        h.hub.notifyDeposit{value: GAS}(poolId, scId, assetId, INVESTOR_A.toBytes32(), maxClaims);

        vm.startPrank(INVESTOR_A);
        vault.mint(INVESTOR_A_AMOUNT, INVESTOR_A);

        assertEq(shareToken.balanceOf(INVESTOR_A), INVESTOR_A_AMOUNT);
    }

    /// forge-config: default.isolate = true
    function testSyncDeposit(bool sameChain) public {
        _setSpoke(sameChain);
        (PoolId poolId, ShareClassId scId, AssetId assetId) = _configurePool(address(s.syncDepositVaultFactory));

        IShareToken shareToken = IShareToken(s.spoke.shareToken(poolId, scId));
        (address asset,) = s.spoke.idToAsset(assetId);
        SyncDepositVault vault = SyncDepositVault(shareToken.vault(address(asset)));

        vm.startPrank(INVESTOR_A);
        ERC20(asset).approve(address(vault), INVESTOR_A_AMOUNT);
        vault.deposit(INVESTOR_A_AMOUNT, INVESTOR_A);

        // TODO: Continue investing process
        //s.balanceSheet.approveDeposits(poolId, scId, assetId, INVESTOR_A_AMOUNT);
        //s.balanceSheet.issue(poolId, scId, assetId, INVESTOR_A_AMOUNT);

        //vault.mint(INVESTOR_A_AMOUNT, INVESTOR_A);
    }
}
