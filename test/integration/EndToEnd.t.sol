// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {ERC20} from "src/misc/ERC20.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";
import {D18, d18} from "src/misc/types/D18.sol";

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

import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {PoolManager} from "src/vaults/PoolManager.sol";
import {BalanceSheet} from "src/vaults/BalanceSheet.sol";
import {AsyncRequests} from "src/vaults/AsyncRequests.sol";
import {SyncRequests} from "src/vaults/SyncRequests.sol";

import {FullDeployer, HubDeployer, VaultsDeployer} from "script/FullDeployer.s.sol";
import {CommonDeployer, MESSAGE_COST_ENV} from "script/CommonDeployer.s.sol";

import {LocalAdapter} from "test/integration/adapters/LocalAdapter.sol";

/// README
/// This EndToEnd tests emulates two chains fully deployed and connected through an adapter
/// Each test case can receive a fuzzed boolean parameter to be tested in both cases:
/// - If sameChain: HUB is in CENTRIFUGE_ID_A and CV is in CENTRIFUGE_ID_A
/// - If !sameChain: HUB is in CENTRIFUGE_ID_A and CV is in CENTRIFUGE_ID_B
///
/// NOTE: All contracts used needs to be placed in the below struct to avoid external calls each time a contract is
/// choosen from a deployment. i.e:
///   vm.prank(FM)
///   deployA.hub().notifyPool() // Will fail, given prank is used to retriver the hub.

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

struct CVaults {
    uint16 centrifugeId;
    // Common
    Root root;
    Guardian guardian;
    Gateway gateway;
    // Vaults
    BalanceSheet balanceSheet;
    AsyncRequests asyncRequests;
    SyncRequests syncRequests;
    PoolManager poolManager;
    VaultRouter vaultRouter;
    address asyncVaultFactory;
    address syncDepositVaultFactory;
    // Hooks
    address restrictedTransfers;
    address freelyTransferable;
}

/// End to end testing assuming two full deployments in two different chains
contract TestEndToEnd is Test {
    using CastLib for *;
    using MessageLib for *;

    ISafe immutable safeAdminA = ISafe(makeAddr("SafeAdminA"));
    ISafe immutable safeAdminB = ISafe(makeAddr("SafeAdminB"));

    uint16 constant CENTRIFUGE_ID_A = 5;
    uint16 constant CENTRIFUGE_ID_B = 6;
    uint64 constant GAS = 100 wei;

    address immutable FM = makeAddr("FM");
    address immutable INVESTOR_A = makeAddr("INVESTOR_A");

    FullDeployer deployA = new FullDeployer();
    FullDeployer deployB = new FullDeployer();

    AssetId USD = deployA.USD();
    CHub h;

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
        public
        returns (LocalAdapter adapter)
    {
        deploy.deployFull(localCentrifugeId, safeAdmin, address(deploy), true);

        adapter = new LocalAdapter(localCentrifugeId, deploy.gateway(), address(deploy));
        deploy.wire(remoteCentrifugeId, adapter, address(deploy));

        vm.startPrank(address(deploy));
        vm.stopPrank();

        deploy.removeFullDeployerAccess(address(deploy));
    }

    function _cv(bool sameChain) public view returns (CVaults memory) {
        FullDeployer deploy = (sameChain) ? deployA : deployB;
        uint16 centrifugeId = (sameChain) ? CENTRIFUGE_ID_A : CENTRIFUGE_ID_B;
        return CVaults({
            centrifugeId: centrifugeId,
            root: deploy.root(),
            guardian: deploy.guardian(),
            gateway: deploy.gateway(),
            balanceSheet: deploy.balanceSheet(),
            asyncRequests: deploy.asyncRequests(),
            syncRequests: deploy.syncRequests(),
            poolManager: deploy.poolManager(),
            vaultRouter: deploy.vaultRouter(),
            restrictedTransfers: deploy.restrictedTransfers(),
            freelyTransferable: deploy.freelyTransferable(),
            asyncVaultFactory: deploy.asyncVaultFactory(),
            syncDepositVaultFactory: deploy.syncDepositVaultFactory()
        });
    }

    /// forge-config: default.isolate = true
    function testConfigurePool(bool sameChain) public {
        CVaults memory cv = _cv(sameChain);

        // Register AssetId

        ERC20 usdc = new ERC20(6);
        usdc.file("name", "USD Coin");
        usdc.file("symbol", "USDC");
        usdc.mint(INVESTOR_A, 10_000_000e6);

        cv.poolManager.registerAsset{value: GAS}(h.centrifugeId, address(usdc), 0);
        AssetId usdcAssetId = newAssetId(cv.centrifugeId, 1);

        // Configure Pool

        vm.prank(address(h.guardian.safe()));
        PoolId poolId = h.guardian.createPool(FM, USD);

        ShareClassId scId = h.shareClassManager.previewNextShareClassId(poolId);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(poolId, bytes("Testing pool"));
        h.hub.addShareClass(poolId, "Tokenized MMF", "MMF", bytes32("salt"), bytes(""));
        h.hub.notifyPool{value: GAS}(poolId, cv.centrifugeId);
        h.hub.notifyShareClass{value: GAS}(poolId, scId, cv.centrifugeId, cv.freelyTransferable.toBytes32());

        h.hub.createAccount(poolId, AccountId.wrap(0x01), true);
        h.hub.createAccount(poolId, AccountId.wrap(0x02), false);
        h.hub.createAccount(poolId, AccountId.wrap(0x03), false);
        h.hub.createAccount(poolId, AccountId.wrap(0x04), false);
        h.hub.createHolding(
            poolId,
            scId,
            usdcAssetId,
            h.identityValuation,
            AccountId.wrap(0x01),
            AccountId.wrap(0x02),
            AccountId.wrap(0x03),
            AccountId.wrap(0x04)
        );

        h.hub.updatePricePoolPerShare(poolId, scId, IDENTITY_PRICE, "");
        h.hub.notifySharePrice{value: GAS}(poolId, scId, cv.centrifugeId);
        h.hub.notifyAssetPrice{value: GAS}(poolId, scId, usdcAssetId);

        h.hub.updateContract{value: GAS}(
            poolId,
            scId,
            cv.centrifugeId,
            address(cv.poolManager).toBytes32(),
            MessageLib.UpdateContractVaultUpdate({
                vaultOrFactory: cv.asyncVaultFactory.toBytes32(),
                assetId: usdcAssetId.raw(),
                kind: uint8(VaultUpdateKind.DeployAndLink)
            }).serialize()
        );
    }
}
