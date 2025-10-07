// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import {CoreInput} from "../../script/CoreDeployer.s.sol";
import {
    FullInput,
    FullActionBatcher,
    FullDeployer,
    AdaptersInput,
    WormholeInput,
    AxelarInput,
    LayerZeroInput
} from "../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {ILayerZeroEndpointV2} from "../../src/adapters/interfaces/ILayerZeroAdapter.sol";
import {IWormholeRelayer, IWormholeDeliveryProvider} from "../../src/adapters/interfaces/IWormholeAdapter.sol";

contract FullDeploymentConfigTest is Test, FullDeployer {
    uint16 constant CENTRIFUGE_ID = 23;
    ISafe immutable ADMIN_SAFE = ISafe(makeAddr("AdminSafe"));
    ISafe immutable OPS_SAFE = ISafe(makeAddr("OpsSafe"));

    address immutable WORMHOLE_RELAYER = makeAddr("WormholeRelayer");
    address immutable WORMHOLE_DELIVERY_PROVIDER = makeAddr("WormholeRelayer");
    uint16 constant WORMHOLE_CHAIN_ID = 23;

    address immutable AXELAR_GATEWAY = makeAddr("AxelarGateway");
    address immutable AXELAR_GAS_SERVICE = makeAddr("AxelarGasService");

    address immutable LAYERZERO_ENDPOINT = makeAddr("LayerZeroEndpoint");
    address immutable LAYERZERO_DELEGATE = makeAddr("LayerZeroDelegate");

    bytes constant SIMPLE_CONTRACT = hex"6001600160005260206000f3";

    function _mockRealWormholeContracts() private {
        vm.mockCall(
            WORMHOLE_RELAYER,
            abi.encodeWithSelector(IWormholeRelayer.getDefaultDeliveryProvider.selector),
            abi.encode(WORMHOLE_DELIVERY_PROVIDER)
        );

        vm.mockCall(
            WORMHOLE_DELIVERY_PROVIDER,
            abi.encodeWithSelector(IWormholeDeliveryProvider.chainId.selector),
            abi.encode(WORMHOLE_CHAIN_ID)
        );
    }

    function _mockRealLayerZeroContracts() private {
        vm.mockCall(
            LAYERZERO_ENDPOINT,
            abi.encodeWithSelector(ILayerZeroEndpointV2.setDelegate.selector),
            abi.encode(LAYERZERO_ENDPOINT)
        );
    }

    /// @dev Mock deployed code for validation check which requires deployed code length > 0
    function _mockBridgeContracts() internal {
        vm.etch(WORMHOLE_RELAYER, SIMPLE_CONTRACT);
        vm.etch(AXELAR_GATEWAY, SIMPLE_CONTRACT);
        vm.etch(AXELAR_GAS_SERVICE, SIMPLE_CONTRACT);
    }

    function setUp() public virtual {
        FullActionBatcher batcher = new FullActionBatcher();

        _mockRealWormholeContracts();
        _mockRealLayerZeroContracts();
        _mockBridgeContracts();
        deployFull(
            FullInput({
                core: CoreInput({centrifugeId: CENTRIFUGE_ID, version: bytes32(0), root: address(0)}),
                adminSafe: ADMIN_SAFE,
                opsSafe: OPS_SAFE,
                adapters: AdaptersInput({
                    wormhole: WormholeInput({shouldDeploy: true, relayer: WORMHOLE_RELAYER}),
                    axelar: AxelarInput({shouldDeploy: true, gateway: AXELAR_GATEWAY, gasService: AXELAR_GAS_SERVICE}),
                    layerZero: LayerZeroInput({shouldDeploy: true, endpoint: LAYERZERO_ENDPOINT, delegate: LAYERZERO_DELEGATE})
                })
            }),
            batcher
        );

        removeFullDeployerAccess(batcher);
    }
}

contract FullDeploymentTestCore is FullDeploymentConfigTest {
    function testGateway(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(multiAdapter));
        vm.assume(nonWard != address(messageDispatcher));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(balanceSheet));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(vaultRouter));

        assertEq(gateway.wards(address(root)), 1);
        assertEq(gateway.wards(address(protocolGuardian)), 1);
        assertEq(gateway.wards(address(multiAdapter)), 1);
        assertEq(gateway.wards(address(messageDispatcher)), 1);
        assertEq(gateway.wards(address(messageProcessor)), 1);
        assertEq(gateway.wards(address(spoke)), 1);
        assertEq(gateway.wards(address(balanceSheet)), 1);
        assertEq(gateway.wards(address(hub)), 1);
        assertEq(gateway.wards(address(vaultRouter)), 1);
        assertEq(gateway.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(gateway.processor()), address(messageProcessor));
        assertEq(address(gateway.adapter()), address(multiAdapter));
        assertEq(address(gateway.messageLimits()), address(gasService));
        assertEq(gateway.localCentrifugeId(), CENTRIFUGE_ID);
    }

    function testMultiAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(gateway));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(hub));

        assertEq(multiAdapter.wards(address(root)), 1);
        assertEq(multiAdapter.wards(address(protocolGuardian)), 1);
        assertEq(multiAdapter.wards(address(opsGuardian)), 1);
        assertEq(multiAdapter.wards(address(gateway)), 1);
        assertEq(multiAdapter.wards(address(messageProcessor)), 1);
        assertEq(multiAdapter.wards(address(hub)), 1);
        assertEq(multiAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(multiAdapter.gateway()), address(gateway));
        assertEq(address(multiAdapter.messageProperties()), address(messageProcessor));
        assertEq(multiAdapter.localCentrifugeId(), CENTRIFUGE_ID);
    }

    function testGasService() public pure {
        // Nothing to check
    }

    function testMessageDispatcher(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(balanceSheet));
        vm.assume(nonWard != address(contractUpdater));
        vm.assume(nonWard != address(vaultRegistry));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(hubHandler));

        assertEq(messageDispatcher.wards(address(root)), 1);
        assertEq(messageDispatcher.wards(address(protocolGuardian)), 1);
        assertEq(messageDispatcher.wards(address(spoke)), 1);
        assertEq(messageDispatcher.wards(address(balanceSheet)), 1);
        assertEq(messageDispatcher.wards(address(vaultRegistry)), 1);
        assertEq(messageDispatcher.wards(address(hub)), 1);
        assertEq(messageDispatcher.wards(address(hubHandler)), 1);
        assertEq(messageDispatcher.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(messageDispatcher.localCentrifugeId(), CENTRIFUGE_ID);
        assertEq(address(messageDispatcher.scheduleAuth()), address(root));
        assertEq(address(messageDispatcher.tokenRecoverer()), address(tokenRecoverer));
        assertEq(address(messageDispatcher.gateway()), address(gateway));
        assertEq(address(messageDispatcher.spoke()), address(spoke));
        assertEq(address(messageDispatcher.balanceSheet()), address(balanceSheet));
        assertEq(address(messageDispatcher.hubHandler()), address(hubHandler));
    }

    function testMessageProcessor(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(gateway));

        assertEq(messageProcessor.wards(address(root)), 1);
        assertEq(messageProcessor.wards(address(gateway)), 1);
        assertEq(messageProcessor.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(messageProcessor.scheduleAuth()), address(root));
        assertEq(address(messageProcessor.tokenRecoverer()), address(tokenRecoverer));
        assertEq(address(messageProcessor.multiAdapter()), address(multiAdapter));
        assertEq(address(messageProcessor.gateway()), address(gateway));
        assertEq(address(messageProcessor.spoke()), address(spoke));
        assertEq(address(messageProcessor.balanceSheet()), address(balanceSheet));
        assertEq(address(messageProcessor.contractUpdater()), address(contractUpdater));
        assertEq(address(messageProcessor.hubHandler()), address(hubHandler));
    }

    function testSpoke(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));
        vm.assume(nonWard != address(vaultRegistry));

        assertEq(spoke.wards(address(root)), 1);
        assertEq(spoke.wards(address(messageProcessor)), 1);
        assertEq(spoke.wards(address(messageDispatcher)), 1);
        assertEq(spoke.wards(address(vaultRegistry)), 1);
        assertEq(spoke.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(spoke.gateway()), address(gateway));
        assertEq(address(spoke.poolEscrowFactory()), address(poolEscrowFactory));
        assertEq(address(spoke.tokenFactory()), address(tokenFactory));
        assertEq(address(spoke.sender()), address(messageDispatcher));
    }

    function testBalanceSheet(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(balanceSheet.wards(address(root)), 1);
        assertEq(balanceSheet.wards(address(messageProcessor)), 1);
        assertEq(balanceSheet.wards(address(messageDispatcher)), 1);
        assertEq(balanceSheet.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(balanceSheet.spoke()), address(spoke));
        assertEq(address(balanceSheet.sender()), address(messageDispatcher));
        assertEq(address(balanceSheet.poolEscrowProvider()), address(poolEscrowFactory));

        // root endorsements
        assertEq(root.endorsed(address(balanceSheet)), true);
    }

    function testVaultRegistry(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(vaultRegistry.wards(address(root)), 1);
        assertEq(vaultRegistry.wards(address(messageProcessor)), 1);
        assertEq(vaultRegistry.wards(address(messageDispatcher)), 1);
        assertEq(vaultRegistry.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(vaultRegistry.spoke()), address(spoke));
    }

    function testPoolEscrowFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(poolEscrowFactory.wards(address(root)), 1);
        assertEq(poolEscrowFactory.wards(address(spoke)), 1);
        assertEq(poolEscrowFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(poolEscrowFactory.root()), address(root));
        assertEq(address(poolEscrowFactory.gateway()), address(gateway));
        assertEq(address(poolEscrowFactory.balanceSheet()), address(balanceSheet));
    }

    function testTokenFactory(address nonWard) public {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(tokenFactory.wards(address(root)), 1);
        assertEq(tokenFactory.wards(address(spoke)), 1);
        assertEq(tokenFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(tokenFactory.root()), address(root));
        assertEq(address(tokenFactory.tokenWards(0)), address(spoke));
        assertEq(address(tokenFactory.tokenWards(1)), address(balanceSheet));

        vm.expectRevert();
        tokenFactory.tokenWards(2);
    }

    function testContractUpdater(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(contractUpdater.wards(address(root)), 1);
        assertEq(contractUpdater.wards(address(messageProcessor)), 1);
        assertEq(contractUpdater.wards(address(messageDispatcher)), 1);
        assertEq(contractUpdater.wards(nonWard), 0);
    }

    function testHub(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(hubHandler));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(hub.wards(address(root)), 1);
        assertEq(hub.wards(address(hubHandler)), 1);
        assertEq(hub.wards(address(opsGuardian)), 1);
        assertEq(hub.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(hub.hubRegistry()), address(hubRegistry));
        assertEq(address(hub.gateway()), address(gateway));
        assertEq(address(hub.holdings()), address(holdings));
        assertEq(address(hub.accounting()), address(accounting));
        assertEq(address(hub.multiAdapter()), address(multiAdapter));
        assertEq(address(hub.shareClassManager()), address(shareClassManager));
        assertEq(address(hub.sender()), address(messageDispatcher));
    }

    function testHubHandler(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(hubHandler.wards(address(root)), 1);
        assertEq(hubHandler.wards(address(messageProcessor)), 1);
        assertEq(hubHandler.wards(address(messageDispatcher)), 1);
        assertEq(hubHandler.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(hubHandler.hub()), address(hub));
        assertEq(address(hubHandler.holdings()), address(holdings));
        assertEq(address(hubHandler.hubRegistry()), address(hubRegistry));
        assertEq(address(hubHandler.shareClassManager()), address(shareClassManager));
    }

    function testHubRegistry(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(hubHandler));

        assertEq(hubRegistry.wards(address(root)), 1);
        assertEq(hubRegistry.wards(address(hub)), 1);
        assertEq(hubRegistry.wards(address(hubHandler)), 1);
        assertEq(hubRegistry.wards(nonWard), 0);

        // initial values set correctly
        assertEq(hubRegistry.decimals(USD_ID), ISO4217_DECIMALS);
        assertEq(hubRegistry.decimals(EUR_ID), ISO4217_DECIMALS);
    }

    function testShareClassManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(hubHandler));

        assertEq(shareClassManager.wards(address(root)), 1);
        assertEq(shareClassManager.wards(address(hub)), 1);
        assertEq(shareClassManager.wards(address(hubHandler)), 1);
        assertEq(shareClassManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(shareClassManager.hubRegistry()), address(hubRegistry));
    }

    function testHoldings(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(hubHandler));

        assertEq(holdings.wards(address(root)), 1);
        assertEq(holdings.wards(address(hub)), 1);
        assertEq(holdings.wards(address(hubHandler)), 1);
        assertEq(holdings.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(holdings.hubRegistry()), address(hubRegistry));
    }

    function testAccounting(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));

        assertEq(accounting.wards(address(root)), 1);
        assertEq(accounting.wards(address(hub)), 1);
        assertEq(accounting.wards(nonWard), 0);
    }
}

contract FullDeploymentTestPeripherals is FullDeploymentConfigTest {
    function testRoot(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(tokenRecoverer));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(root.wards(address(protocolGuardian)), 1);
        assertEq(root.wards(address(tokenRecoverer)), 1);
        assertEq(root.wards(address(messageProcessor)), 1);
        assertEq(root.wards(address(messageDispatcher)), 1);
        assertEq(root.wards(nonWard), 0);
    }

    function testTokenRecoverer(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(tokenRecoverer.wards(address(root)), 1);
        assertEq(tokenRecoverer.wards(address(protocolGuardian)), 1);
        assertEq(tokenRecoverer.wards(address(messageProcessor)), 1);
        assertEq(tokenRecoverer.wards(address(messageDispatcher)), 1);
        assertEq(tokenRecoverer.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(tokenRecoverer.root()), address(root));
    }

    function testProtocolGuardian() public view {
        // dependencies set correctly
        assertEq(address(protocolGuardian.root()), address(root));
        assertEq(address(protocolGuardian.safe()), address(ADMIN_SAFE));
        assertEq(address(protocolGuardian.gateway()), address(gateway));
        assertEq(address(protocolGuardian.multiAdapter()), address(multiAdapter));
        assertEq(address(protocolGuardian.sender()), address(messageDispatcher));
    }

    function testOpsGuardian() public view {
        // dependencies set correctly
        assertEq(address(opsGuardian.opsSafe()), address(OPS_SAFE));
        assertEq(address(opsGuardian.multiAdapter()), address(multiAdapter));
        assertEq(address(opsGuardian.hub()), address(hub));
    }

    function testRouterEscrow(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(vaultRouter));

        assertEq(routerEscrow.wards(address(root)), 1);
        assertEq(routerEscrow.wards(address(vaultRouter)), 1);
        assertEq(routerEscrow.wards(nonWard), 0);
    }

    function testGlobalEscrow(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(asyncRequestManager));

        assertEq(globalEscrow.wards(address(root)), 1);
        assertEq(globalEscrow.wards(address(asyncRequestManager)), 1);
        assertEq(globalEscrow.wards(nonWard), 0);

        // root endorsements
        assertEq(root.endorsed(address(globalEscrow)), true);
    }

    function testAsyncRequestManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));
        vm.assume(nonWard != address(syncDepositVaultFactory));
        vm.assume(nonWard != address(asyncVaultFactory));
        vm.assume(nonWard != address(contractUpdater));

        assertEq(asyncRequestManager.wards(address(root)), 1);
        assertEq(asyncRequestManager.wards(address(spoke)), 1);
        assertEq(asyncRequestManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(asyncRequestManager.wards(address(asyncVaultFactory)), 1);
        assertEq(asyncRequestManager.wards(address(contractUpdater)), 1);
        assertEq(asyncRequestManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(asyncRequestManager.spoke()), address(spoke));
        assertEq(address(asyncRequestManager.balanceSheet()), address(balanceSheet));
        assertEq(address(asyncRequestManager.globalEscrow()), address(globalEscrow));
        assertEq(address(asyncRequestManager.refundEscrowFactory()), address(refundEscrowFactory));

        // root endorsements
        assertEq(root.endorsed(address(balanceSheet)), true);
    }

    function testAsyncVaultFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(vaultRegistry));

        assertEq(asyncVaultFactory.wards(address(root)), 1);
        assertEq(asyncVaultFactory.wards(address(vaultRegistry)), 1);
        assertEq(asyncVaultFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(asyncVaultFactory.root()), address(root));
        assertEq(address(asyncVaultFactory.asyncRequestManager()), address(asyncRequestManager));
    }

    function testSyncDepositVaultFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(vaultRegistry));

        assertEq(syncDepositVaultFactory.wards(address(root)), 1);
        assertEq(syncDepositVaultFactory.wards(address(vaultRegistry)), 1);
        assertEq(syncDepositVaultFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(syncDepositVaultFactory.root()), address(root));
        assertEq(address(syncDepositVaultFactory.syncDepositManager()), address(syncManager));
        assertEq(address(syncDepositVaultFactory.asyncRedeemManager()), address(asyncRequestManager));
    }

    function testSyncManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(contractUpdater));
        vm.assume(nonWard != address(syncDepositVaultFactory));

        assertEq(syncManager.wards(address(root)), 1);
        assertEq(syncManager.wards(address(contractUpdater)), 1);
        assertEq(syncManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(syncManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(syncManager.spoke()), address(spoke));
        assertEq(address(syncManager.balanceSheet()), address(balanceSheet));
    }

    function testVaultRouter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));

        assertEq(vaultRouter.wards(address(root)), 1);
        assertEq(vaultRouter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(vaultRouter.spoke()), address(spoke));
        assertEq(address(vaultRouter.escrow()), address(routerEscrow));
        assertEq(address(vaultRouter.gateway()), address(gateway));

        // root endorsements
        assertEq(root.endorsed(address(vaultRouter)), true);
    }

    function testRefundEscrowFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(asyncRequestManager));

        assertEq(refundEscrowFactory.wards(address(root)), 1);
        assertEq(refundEscrowFactory.wards(address(asyncRequestManager)), 1);
        assertEq(refundEscrowFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(refundEscrowFactory.controller()), address(asyncRequestManager));
    }

    function testFreezeOnly(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(freezeOnlyHook.wards(address(root)), 1);
        assertEq(freezeOnlyHook.wards(address(spoke)), 1);
        assertEq(freezeOnlyHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(freezeOnlyHook.root()), address(root));
    }

    function testRedemptionRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(redemptionRestrictionsHook.wards(address(root)), 1);
        assertEq(redemptionRestrictionsHook.wards(address(spoke)), 1);
        assertEq(redemptionRestrictionsHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(redemptionRestrictionsHook.root()), address(root));
    }

    function testFreelyTransferable(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(freelyTransferableHook.wards(address(root)), 1);
        assertEq(freelyTransferableHook.wards(address(spoke)), 1);
        assertEq(freelyTransferableHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(freelyTransferableHook.root()), address(root));
    }

    function testFullRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(fullRestrictionsHook.wards(address(root)), 1);
        assertEq(fullRestrictionsHook.wards(address(spoke)), 1);
        assertEq(fullRestrictionsHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(fullRestrictionsHook.root()), address(root));
    }

    function testOnOfframpManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(onOfframpManagerFactory.contractUpdater()), address(contractUpdater));
        assertEq(address(onOfframpManagerFactory.balanceSheet()), address(balanceSheet));
    }

    function testMerkleProofManagerFactory() public view {
        // dependencies set correctly
        assertEq(address(merkleProofManagerFactory.contractUpdater()), address(contractUpdater));
        assertEq(address(merkleProofManagerFactory.balanceSheet()), address(balanceSheet));
    }

    function testQueueManager() public view {
        // dependencies set correctly
        assertEq(address(queueManager.contractUpdater()), address(contractUpdater));
        assertEq(address(queueManager.balanceSheet()), address(balanceSheet));
        assertEq(address(queueManager.gateway()), address(gateway));
    }

    function testIdentityValuation() public view {
        // dependencies set correctly
        assertEq(address(identityValuation.hubRegistry()), address(hubRegistry));
    }

    function testOracleValuation() public view {
        // dependencies set correctly
        assertEq(address(oracleValuation.hubRegistry()), address(hubRegistry));
        assertEq(address(oracleValuation.hub()), address(hub));
    }

    function testNavManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(holdings));
        vm.assume(nonWard != address(hubHandler));

        assertEq(navManager.wards(address(holdings)), 1);
        assertEq(navManager.wards(address(hubHandler)), 1);
        assertEq(navManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(navManager.hub()), address(hub));
    }

    function testSimplePriceManager() public view {
        // dependencies set correctly
        assertEq(address(simplePriceManager.hub()), address(hub));
    }

    function testWormholeAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(protocolGuardian));

        assertEq(wormholeAdapter.wards(address(root)), 1);
        assertEq(wormholeAdapter.wards(address(opsGuardian)), 1);
        assertEq(wormholeAdapter.wards(address(protocolGuardian)), 1);
        assertEq(wormholeAdapter.wards(address(ADMIN_SAFE)), 0);
        assertEq(wormholeAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(wormholeAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(wormholeAdapter.relayer()), WORMHOLE_RELAYER);
        assertEq(wormholeAdapter.localWormholeId(), WORMHOLE_CHAIN_ID);
    }

    function testAxelarAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(protocolGuardian));

        assertEq(axelarAdapter.wards(address(root)), 1);
        assertEq(axelarAdapter.wards(address(opsGuardian)), 1);
        assertEq(axelarAdapter.wards(address(protocolGuardian)), 1);
        assertEq(axelarAdapter.wards(address(ADMIN_SAFE)), 0);
        assertEq(axelarAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(axelarAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(axelarAdapter.axelarGateway()), AXELAR_GATEWAY);
        assertEq(address(axelarAdapter.axelarGasService()), AXELAR_GAS_SERVICE);
    }

    function testLayerZeroAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(ADMIN_SAFE));

        assertEq(layerZeroAdapter.wards(address(root)), 1);
        assertEq(layerZeroAdapter.wards(address(opsGuardian)), 1);
        assertEq(layerZeroAdapter.wards(address(protocolGuardian)), 1);
        assertEq(layerZeroAdapter.wards(address(ADMIN_SAFE)), 1);
        assertEq(layerZeroAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(layerZeroAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(layerZeroAdapter.endpoint()), LAYERZERO_ENDPOINT);
    }
}

contract FullDeploymentTestAdaptersValidation is FullDeploymentConfigTest {
    function _mockNonEmptyContract(address contractAddr) internal {
        vm.etch(contractAddr, SIMPLE_CONTRACT);
    }

    function _validateWormholeInput(AdaptersInput memory adaptersInput) private view {
        if (adaptersInput.wormhole.shouldDeploy) {
            require(adaptersInput.wormhole.relayer != address(0), "Wormhole relayer address cannot be zero");
            require(adaptersInput.wormhole.relayer.code.length > 0, "Wormhole relayer must be a deployed contract");
        }
    }

    function _validateAxelarInput(AdaptersInput memory adaptersInput) private view {
        if (adaptersInput.axelar.shouldDeploy) {
            require(adaptersInput.axelar.gateway != address(0), "Axelar gateway address cannot be zero");
            require(adaptersInput.axelar.gasService != address(0), "Axelar gas service address cannot be zero");
            require(adaptersInput.axelar.gateway.code.length > 0, "Axelar gateway must be a deployed contract");
            require(adaptersInput.axelar.gasService.code.length > 0, "Axelar gas service must be a deployed contract");
        }
    }

    function _validateLayerZeroInput(AdaptersInput memory adaptersInput) private view {
        if (adaptersInput.layerZero.shouldDeploy) {
            require(adaptersInput.layerZero.endpoint != address(0), "LayerZero endpoint address cannot be zero");
            require(adaptersInput.layerZero.endpoint.code.length > 0, "LayerZero endpoint must be a deployed contract");
            require(adaptersInput.layerZero.delegate != address(0), "LayerZero delegate address cannot be zero");
        }
    }

    function testWormholeRelayerZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Wormhole relayer address cannot be zero");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testWormholeRelayerNoCodeFails() public {
        address mockRelayer = makeAddr("MockRelayerNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: true, relayer: mockRelayer}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Wormhole relayer must be a deployed contract");
        this._validateWormholeInputExternal(invalidInput);
    }

    function testAxelarGatewayZeroAddressFails() public {
        address validGasService = makeAddr("ValidGasService");
        _mockNonEmptyContract(validGasService);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: address(0), gasService: validGasService}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gateway address cannot be zero");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGasServiceZeroAddressFails() public {
        address validGateway = makeAddr("ValidGateway");
        _mockNonEmptyContract(validGateway);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: validGateway, gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gas service address cannot be zero");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGatewayNoCodeFails() public {
        address mockGateway = makeAddr("MockGatewayNoCode");
        address mockGasService = makeAddr("MockGasService");

        // Mock code for gas service but not gateway
        _mockNonEmptyContract(mockGasService);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gateway must be a deployed contract");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGasServiceNoCodeFails() public {
        address mockGateway = makeAddr("MockGateway");
        address mockGasService = makeAddr("MockGasServiceNoCode");

        // Mock code for gateway but not gas service
        _mockNonEmptyContract(mockGateway);

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService}),
            layerZero: LayerZeroInput({shouldDeploy: false, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("Axelar gas service must be a deployed contract");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testLayerZeroEndpointZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: address(0), delegate: address(0)})
        });

        vm.expectRevert("LayerZero endpoint address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testLayerZeroEndpointNoCodeFails() public {
        address mockEndpoint = makeAddr("MockEndpointNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: mockEndpoint, delegate: address(0)})
        });

        vm.expectRevert("LayerZero endpoint must be a deployed contract");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testLayerZeroDelegateZeroAddressFails() public {
        // Etch some non-zero code to enable the endpoint test to pass
        vm.etch(LAYERZERO_ENDPOINT, bytes("0x01"));

        AdaptersInput memory invalidInput = AdaptersInput({
            wormhole: WormholeInput({shouldDeploy: false, relayer: address(0)}),
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({shouldDeploy: true, endpoint: LAYERZERO_ENDPOINT, delegate: address(0)})
        });

        vm.expectRevert("LayerZero delegate address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    // External wrapper functions to allow expectRevert to work properly (must be external)
    function _validateWormholeInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateWormholeInput(adaptersInput);
    }

    function _validateAxelarInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateAxelarInput(adaptersInput);
    }

    function _validateLayerZeroInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateLayerZeroInput(adaptersInput);
    }
}
