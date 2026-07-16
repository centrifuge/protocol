// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import {
    DeployerInput,
    FullDeployer,
    AdaptersInput,
    AxelarInput,
    LayerZeroInput,
    ChainlinkInput,
    HyperlaneInput,
    defaultTxLimits,
    AdapterConnections
} from "../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {ILayerZeroEndpointV2Like, SetConfigParam} from "../../src/deployment/interfaces/ILayerZeroEndpointV2Like.sol";

contract LayerZeroEndpointMock {
    mapping(address oapp => address delegate) public delegates;

    function setDelegate(address _delegate) external {
        delegates[msg.sender] = _delegate;
    }
}

contract FullDeploymentConfigTest is Test, FullDeployer {
    uint16 constant CENTRIFUGE_ID = 23;
    ISafe immutable ADMIN_SAFE = ISafe(makeAddr("AdminSafe"));
    ISafe immutable OPS_SAFE = ISafe(makeAddr("OpsSafe"));

    address immutable AXELAR_GATEWAY = makeAddr("AxelarGateway");
    address immutable AXELAR_GAS_SERVICE = makeAddr("AxelarGasService");

    address immutable LAYERZERO_ENDPOINT = address(new LayerZeroEndpointMock());
    address immutable LAYERZERO_DELEGATE = makeAddr("LayerZeroDelegate");

    address immutable CHAINLINK_CCIP_ROUTER = makeAddr("ChainlinkCCIPRouter");

    address immutable HYPERLANE_MAILBOX = makeAddr("HyperlaneMailbox");

    bytes constant SIMPLE_CONTRACT = hex"6001600160005260206000f3";

    /// @dev Mock deployed code for validation check which requires deployed code length > 0
    function _mockBridgeContracts() internal {
        vm.etch(AXELAR_GATEWAY, SIMPLE_CONTRACT);
        vm.etch(AXELAR_GAS_SERVICE, SIMPLE_CONTRACT);
        vm.etch(CHAINLINK_CCIP_ROUTER, SIMPLE_CONTRACT);
        vm.etch(HYPERLANE_MAILBOX, SIMPLE_CONTRACT);
    }

    function setUp() public virtual {
        _mockBridgeContracts();
        deployFull(
            DeployerInput({
                centrifugeId: CENTRIFUGE_ID,
                suffix: "",
                txLimits: defaultTxLimits(),
                protocolSafe: ADMIN_SAFE,
                opsSafe: OPS_SAFE,
                adapters: AdaptersInput({
                    axelar: AxelarInput({shouldDeploy: true, gateway: AXELAR_GATEWAY, gasService: AXELAR_GAS_SERVICE}),
                    layerZero: LayerZeroInput({
                        shouldDeploy: true,
                        endpoint: LAYERZERO_ENDPOINT,
                        delegate: LAYERZERO_DELEGATE,
                        configParams: new SetConfigParam[](0)
                    }),
                    chainlink: ChainlinkInput({shouldDeploy: true, ccipRouter: CHAINLINK_CCIP_ROUTER}),
                    hyperlane: HyperlaneInput({shouldDeploy: true, mailbox: HYPERLANE_MAILBOX, ism: address(0)}),
                    connections: new AdapterConnections[](0) // TODO: test this
                })
            }),
            address(this)
        );
    }
}

contract FullDeploymentTestCore is FullDeploymentConfigTest {
    function testGateway(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(multiAdapter));
        vm.assume(nonWard != address(messageDispatcher));
        vm.assume(nonWard != address(messageProcessor));

        assertEq(gateway.wards(address(root)), 1);
        assertEq(gateway.wards(address(protocolGuardian)), 1);
        assertEq(gateway.wards(address(opsGuardian)), 1);
        assertEq(gateway.wards(address(multiAdapter)), 1);
        assertEq(gateway.wards(address(messageDispatcher)), 1);
        assertEq(gateway.wards(address(messageProcessor)), 1);
        assertEq(gateway.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(gateway.localCentrifugeId(), CENTRIFUGE_ID);
        assertEq(address(gateway.processor()), address(messageProcessor));
        assertEq(address(gateway.adapter()), address(multiAdapter));
        assertEq(address(gateway.messageProperties()), address(gasService));
    }

    function testMultiAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(gateway));
        vm.assume(nonWard != address(messageDispatcher));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(hub));

        assertEq(multiAdapter.wards(address(root)), 1);
        assertEq(multiAdapter.wards(address(protocolGuardian)), 1);
        assertEq(multiAdapter.wards(address(opsGuardian)), 1);
        assertEq(multiAdapter.wards(address(gateway)), 1);
        assertEq(multiAdapter.wards(address(messageDispatcher)), 1);
        assertEq(multiAdapter.wards(address(messageProcessor)), 1);
        assertEq(multiAdapter.wards(address(hub)), 1);
        assertEq(multiAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(multiAdapter.gateway()), address(gateway));
        assertEq(address(multiAdapter.messageProperties()), address(gasService));
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
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(hubHandler));
        vm.assume(nonWard != address(spokeV3_1_0));

        assertEq(messageDispatcher.wards(address(root)), 1);
        assertEq(messageDispatcher.wards(address(protocolGuardian)), 1);
        assertEq(messageDispatcher.wards(address(spoke)), 1);
        assertEq(messageDispatcher.wards(address(hub)), 1);
        assertEq(messageDispatcher.wards(address(hubHandler)), 1);
        assertEq(messageDispatcher.wards(address(spokeV3_1_0)), 1);
        assertEq(messageDispatcher.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(messageDispatcher.localCentrifugeId(), CENTRIFUGE_ID);
        assertEq(address(messageDispatcher.scheduleAuth()), address(root));
        assertEq(address(messageDispatcher.gateway()), address(gateway));
        assertEq(address(messageDispatcher.spokeHandler()), address(spokeHandler));
        assertEq(address(messageDispatcher.multiAdapter()), address(multiAdapter));
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
        assertEq(address(messageProcessor.gateway()), address(gateway));
        assertEq(address(messageProcessor.spokeHandler()), address(spokeHandler));
        assertEq(address(messageProcessor.multiAdapter()), address(multiAdapter));
        assertEq(address(messageProcessor.hubHandler()), address(hubHandler));
    }

    function testSpokeRegistry(address nonWard) public view {
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spokeHandler));
        vm.assume(nonWard != address(spoke));

        assertEq(spokeRegistry.wards(address(root)), 1);
        assertEq(spokeRegistry.wards(address(spokeHandler)), 1);
        assertEq(spokeRegistry.wards(address(spoke)), 1);
        assertEq(spokeRegistry.wards(nonWard), 0);
    }

    function testSpokeHandler(address nonWard) public view {
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(spokeHandler.wards(address(root)), 1);
        assertEq(spokeHandler.wards(address(messageProcessor)), 1);
        assertEq(spokeHandler.wards(address(messageDispatcher)), 1);
        assertEq(spokeHandler.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(spokeHandler.spokeRegistry()), address(spokeRegistry));
        assertEq(address(spokeHandler.poolEscrowFactory()), address(poolEscrowFactory));
    }

    function testSpoke(address nonWard) public view {
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spokeV3_1_0));

        assertEq(spoke.wards(address(root)), 1);
        // SpokeV3_1_0 is warded on Spoke so it can forward crosschainTransferShares on the caller's behalf.
        assertEq(spoke.wards(address(spokeV3_1_0)), 1);
        assertEq(spoke.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(spoke.spokeRegistry()), address(spokeRegistry));
        assertEq(address(spoke.sender()), address(messageDispatcher));
        assertEq(address(spoke.snapshotQueue()), address(snapshotQueue));
        assertEq(address(spoke.poolEscrowProvider()), address(poolEscrowFactory));

        // root endorsements
        assertEq(root.endorsed(address(spoke)), true);
    }

    function testQueues(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spoke));

        assertEq(snapshotQueue.wards(address(root)), 1);
        assertEq(snapshotQueue.wards(address(spoke)), 1);
        assertEq(snapshotQueue.wards(nonWard), 0);
    }

    function testPoolEscrowFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spokeHandler));

        assertEq(poolEscrowFactory.wards(address(root)), 1);
        assertEq(poolEscrowFactory.wards(address(spokeHandler)), 1);
        assertEq(poolEscrowFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(poolEscrowFactory.root()), address(root));
        assertEq(address(poolEscrowFactory.spoke()), address(spoke));
    }

    function testShareTokenRegistrar(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spokeHandler));
        vm.assume(nonWard != address(spoke));

        assertEq(shareTokenRegistrar.wards(address(root)), 1);
        assertEq(shareTokenRegistrar.wards(address(spokeHandler)), 1);
        assertEq(shareTokenRegistrar.wards(address(spoke)), 1);
        assertEq(shareTokenRegistrar.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(shareTokenRegistrar.root()), address(root));
        assertEq(address(shareTokenRegistrar.envoy()), address(envoy));
        assertEq(address(shareTokenRegistrar.spokeRegistry()), address(spokeRegistry));
    }

    function testContractUpdater(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(contractUpdaterForwarder));

        assertEq(contractUpdater.wards(address(root)), 1);
        assertEq(contractUpdater.wards(address(contractUpdaterForwarder)), 1);
        assertEq(contractUpdater.wards(nonWard), 0);
    }

    function testEnvoy(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(messageDispatcher));
        vm.assume(nonWard != address(messageProcessor));

        assertEq(envoy.wards(address(root)), 1);
        assertEq(envoy.wards(address(messageDispatcher)), 1);
        assertEq(envoy.wards(address(messageProcessor)), 1);
        assertEq(envoy.wards(nonWard), 0);
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

contract FullDeploymentTestNonCore is FullDeploymentConfigTest {
    function testRoot(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(messageProcessor));
        vm.assume(nonWard != address(messageDispatcher));

        assertEq(root.wards(address(protocolGuardian)), 1);
        assertEq(root.wards(address(messageProcessor)), 1);
        assertEq(root.wards(address(messageDispatcher)), 1);
        assertEq(root.wards(nonWard), 0);
    }

    function testProtocolGuardian() public view {
        // dependencies set correctly
        assertEq(address(protocolGuardian.root()), address(root));
        assertEq(address(protocolGuardian.safe()), address(ADMIN_SAFE));
        assertEq(address(protocolGuardian.sender()), address(messageDispatcher));
    }

    function testOpsGuardian() public view {
        // dependencies set correctly
        assertEq(address(opsGuardian.opsSafe()), address(OPS_SAFE));
        assertEq(address(opsGuardian.multiAdapter()), address(multiAdapter));
        assertEq(address(opsGuardian.hub()), address(hub));
    }

    function testSubsidyManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(asyncRequestManager));

        assertEq(subsidyManager.wards(address(root)), 1);
        assertEq(subsidyManager.wards(address(asyncRequestManager)), 1);
        assertEq(subsidyManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(subsidyManager.refundEscrowFactory()), address(refundEscrowFactory));
        assertEq(subsidyManager.envoy(), address(envoy));
    }

    function testAsyncRequestManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spokeHandler));
        vm.assume(nonWard != address(syncDepositVaultFactory));
        vm.assume(nonWard != address(asyncVaultFactory));
        vm.assume(nonWard != address(contractUpdater));

        assertEq(asyncRequestManager.wards(address(root)), 1);
        assertEq(asyncRequestManager.wards(address(spokeHandler)), 1);
        assertEq(asyncRequestManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(asyncRequestManager.wards(address(asyncVaultFactory)), 1);
        assertEq(asyncRequestManager.wards(address(contractUpdater)), 1);
        assertEq(asyncRequestManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(asyncRequestManager.spoke()), address(spoke));
        assertEq(address(asyncRequestManager.spokeRegistry()), address(spokeRegistry));
        assertEq(address(asyncRequestManager.subsidyManager()), address(subsidyManager));

        // root endorsements
        assertEq(root.endorsed(address(spoke)), true);
    }

    function testAsyncVaultFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spokeHandler));

        assertEq(asyncVaultFactory.wards(address(root)), 1);
        assertEq(asyncVaultFactory.wards(address(spokeHandler)), 1);
        assertEq(asyncVaultFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(asyncVaultFactory.root()), address(root));
        assertEq(address(asyncVaultFactory.asyncRequestManager()), address(asyncRequestManager));
    }

    function testSyncDepositVaultFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(spokeHandler));

        assertEq(syncDepositVaultFactory.wards(address(root)), 1);
        assertEq(syncDepositVaultFactory.wards(address(spokeHandler)), 1);
        assertEq(syncDepositVaultFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(syncDepositVaultFactory.root()), address(root));
        assertEq(address(syncDepositVaultFactory.syncDepositManager()), address(syncManager));
        assertEq(address(syncDepositVaultFactory.asyncRedeemManager()), address(asyncRequestManager));
    }

    function testSyncManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(syncDepositVaultFactory));

        assertEq(syncManager.wards(address(root)), 1);
        assertEq(syncManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(syncManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(syncManager.spoke()), address(spoke));
        assertEq(address(syncManager.spokeRegistry()), address(spokeRegistry));
        assertEq(syncManager.envoy(), address(envoy));
    }

    function testVaultRouter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));

        assertEq(vaultRouter.wards(address(root)), 1);
        assertEq(vaultRouter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(vaultRouter.spoke()), address(spoke));
        assertEq(address(vaultRouter.gateway()), address(gateway));

        // root endorsements
        assertEq(root.endorsed(address(vaultRouter)), true);
    }

    function testRefundEscrowFactory(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(subsidyManager));

        assertEq(refundEscrowFactory.wards(address(root)), 1);
        assertEq(refundEscrowFactory.wards(address(subsidyManager)), 1);
        assertEq(refundEscrowFactory.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(refundEscrowFactory.controller()), address(subsidyManager));
    }

    function testFreezeOnly(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(shareTokenRegistrar));

        assertEq(freezeOnlyHook.wards(address(root)), 1);
        assertEq(freezeOnlyHook.wards(address(shareTokenRegistrar)), 1);
        assertEq(freezeOnlyHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(freezeOnlyHook.root()), address(root));
        assertEq(freezeOnlyHook.envoy(), address(envoy));
    }

    function testRedemptionRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(shareTokenRegistrar));

        assertEq(redemptionRestrictionsHook.wards(address(root)), 1);
        assertEq(redemptionRestrictionsHook.wards(address(shareTokenRegistrar)), 1);
        assertEq(redemptionRestrictionsHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(redemptionRestrictionsHook.root()), address(root));
        assertEq(redemptionRestrictionsHook.envoy(), address(envoy));
    }

    function testFreelyTransferable(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(shareTokenRegistrar));

        assertEq(freelyTransferableHook.wards(address(root)), 1);
        assertEq(freelyTransferableHook.wards(address(shareTokenRegistrar)), 1);
        assertEq(freelyTransferableHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(freelyTransferableHook.root()), address(root));
        assertEq(freelyTransferableHook.envoy(), address(envoy));
    }

    function testFullRestriction(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(shareTokenRegistrar));

        assertEq(fullRestrictionsHook.wards(address(root)), 1);
        assertEq(fullRestrictionsHook.wards(address(shareTokenRegistrar)), 1);
        assertEq(fullRestrictionsHook.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(fullRestrictionsHook.root()), address(root));
        assertEq(fullRestrictionsHook.envoy(), address(envoy));
    }

    function testOnOffRampFactory() public view {
        // dependencies set correctly
        assertEq(address(onOffRampFactory.envoy()), address(envoy));
        assertEq(address(onOffRampFactory.spoke()), address(spoke));
        assertEq(address(onOffRampFactory.accountingToken()), address(accountingToken));
    }

    function testQueueManager() public view {
        // dependencies set correctly
        assertEq(address(queueManager.envoy()), address(envoy));
        assertEq(address(queueManager.spoke()), address(spoke));
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
        assertEq(oracleValuation.envoy(), address(envoy));
    }

    function testNavManager() public view {
        // dependencies set correctly
        assertEq(address(navManager.hub()), address(hub));
        assertEq(address(navManager.holdings()), address(holdings));
        assertEq(navManager.envoy(), address(envoy));
    }

    function testSimplePriceManager() public view {
        // dependencies set correctly
        assertEq(address(simplePriceManager.navUpdater()), address(navManager));

        // dependencies set correctly
        assertEq(address(simplePriceManager.hub()), address(hub));
    }

    function testBatchRequestManager(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(hub));
        vm.assume(nonWard != address(hubHandler));
        vm.assume(nonWard != address(contractUpdater));

        assertEq(batchRequestManager.wards(address(root)), 1);
        assertEq(batchRequestManager.wards(address(hub)), 1);
        assertEq(batchRequestManager.wards(address(hubHandler)), 1);
        assertEq(batchRequestManager.wards(address(contractUpdater)), 1);
        assertEq(batchRequestManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(batchRequestManager.envoy(), address(envoy));
    }

    function testOnchainPMFactory() public view {
        // dependencies set correctly
        assertEq(onchainPMFactory.contractUpdater(), address(contractUpdater));
        assertEq(address(onchainPMFactory.spoke()), address(spoke));
        assertEq(address(onchainPMFactory.gateway()), address(gateway));
    }

    function testScriptHelpers() public view {
        // contract deployed
        assertTrue(address(scriptHelpers).code.length > 0);
    }

    function testFlashLoanHelper() public view {
        // contract deployed
        assertTrue(address(flashLoanHelper).code.length > 0);
    }

    function testApprovalGuard() public view {
        // contract deployed
        assertTrue(address(approvalGuard).code.length > 0);
    }

    function testCircuitBreakerGuard() public view {
        // contract deployed
        assertTrue(address(circuitBreakerGuard).code.length > 0);
    }

    function testBridgeCircuitBreaker() public view {
        // dependencies set correctly
        assertEq(bridgeCircuitBreaker.envoy(), address(envoy));
        assertEq(bridgeCircuitBreaker.hubHandler(), address(hubHandler));
        assertEq(address(bridgeCircuitBreaker.circuitBreakerGuard()), address(circuitBreakerGuard));
    }

    function testSlippageGuard() public view {
        // dependencies set correctly
        assertEq(address(slippageGuard.spoke()), address(spoke));
        assertEq(slippageGuard.envoy(), address(envoy));
        assertEq(address(slippageGuard.onchainPMFactory()), address(onchainPMFactory));
    }
}

contract FullDeploymentTestAdapters is FullDeploymentConfigTest {
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
        assertEq(
            address(
                ILayerZeroEndpointV2Like(address(layerZeroAdapter.endpoint())).delegates(address(layerZeroAdapter))
            ),
            LAYERZERO_DELEGATE
        );
    }

    function testChainlinkAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(protocolGuardian));

        assertEq(chainlinkAdapter.wards(address(root)), 1);
        assertEq(chainlinkAdapter.wards(address(opsGuardian)), 1);
        assertEq(chainlinkAdapter.wards(address(protocolGuardian)), 1);
        assertEq(chainlinkAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(chainlinkAdapter.ccipRouter()), CHAINLINK_CCIP_ROUTER);
    }

    function testHyperlaneAdapter(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(opsGuardian));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(ADMIN_SAFE));

        assertEq(hyperlaneAdapter.wards(address(root)), 1);
        assertEq(hyperlaneAdapter.wards(address(opsGuardian)), 1);
        assertEq(hyperlaneAdapter.wards(address(protocolGuardian)), 1);
        assertEq(hyperlaneAdapter.wards(address(ADMIN_SAFE)), 1);
        assertEq(hyperlaneAdapter.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(hyperlaneAdapter.entrypoint()), address(multiAdapter));
        assertEq(address(hyperlaneAdapter.mailbox()), HYPERLANE_MAILBOX);
    }

    function testAdapterFailover() public view {
        assertEq(address(adapterFailover.multiAdapter()), address(multiAdapter));
        assertEq(adapterFailover.envoy(), address(envoy));
        assertEq(adapterFailover.timelock(), uint64(DELAY));
    }
}

contract FullDeploymentTestAdaptersValidation is FullDeploymentConfigTest {
    function _mockNonEmptyContract(address contractAddr) internal {
        vm.etch(contractAddr, SIMPLE_CONTRACT);
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

    function _validateChainlinkInput(AdaptersInput memory adaptersInput) private view {
        if (adaptersInput.chainlink.shouldDeploy) {
            require(adaptersInput.chainlink.ccipRouter != address(0), "Chainlink ccipRouter address cannot be zero");
            require(
                adaptersInput.chainlink.ccipRouter.code.length > 0, "Chainlink ccipRouter must be a deployed contract"
            );
        }
    }

    function testAxelarGatewayZeroAddressFails() public {
        address validGasService = makeAddr("ValidGasService");
        _mockNonEmptyContract(validGasService);

        AdaptersInput memory invalidInput = AdaptersInput({
            axelar: AxelarInput({shouldDeploy: true, gateway: address(0), gasService: validGasService}),
            layerZero: LayerZeroInput({
                shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
        });

        vm.expectRevert("Axelar gateway address cannot be zero");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testAxelarGasServiceZeroAddressFails() public {
        address validGateway = makeAddr("ValidGateway");
        _mockNonEmptyContract(validGateway);

        AdaptersInput memory invalidInput = AdaptersInput({
            axelar: AxelarInput({shouldDeploy: true, gateway: validGateway, gasService: address(0)}),
            layerZero: LayerZeroInput({
                shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
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
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService}),
            layerZero: LayerZeroInput({
                shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
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
            axelar: AxelarInput({shouldDeploy: true, gateway: mockGateway, gasService: mockGasService}),
            layerZero: LayerZeroInput({
                shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
        });

        vm.expectRevert("Axelar gas service must be a deployed contract");
        this._validateAxelarInputExternal(invalidInput);
    }

    function testLayerZeroEndpointZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({
                shouldDeploy: true, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
        });

        vm.expectRevert("LayerZero endpoint address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testLayerZeroEndpointNoCodeFails() public {
        address mockEndpoint = makeAddr("MockEndpointNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({
                shouldDeploy: true, endpoint: mockEndpoint, delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
        });

        vm.expectRevert("LayerZero endpoint must be a deployed contract");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testLayerZeroDelegateZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({
                shouldDeploy: true,
                endpoint: LAYERZERO_ENDPOINT,
                delegate: address(0),
                configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: false, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
        });

        vm.expectRevert("LayerZero delegate address cannot be zero");
        this._validateLayerZeroInputExternal(invalidInput);
    }

    function testChainlinkZeroAddressFails() public {
        AdaptersInput memory invalidInput = AdaptersInput({
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({
                shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: true, ccipRouter: address(0)}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
        });

        vm.expectRevert("Chainlink ccipRouter address cannot be zero");
        this._validateChainlinkInputExternal(invalidInput);
    }

    function testChainlinkNoCodeFails() public {
        address mockCCIPRouter = makeAddr("MockCCIPRouterNoCode");
        AdaptersInput memory invalidInput = AdaptersInput({
            axelar: AxelarInput({shouldDeploy: false, gateway: address(0), gasService: address(0)}),
            layerZero: LayerZeroInput({
                shouldDeploy: false, endpoint: address(0), delegate: address(0), configParams: new SetConfigParam[](0)
            }),
            chainlink: ChainlinkInput({shouldDeploy: true, ccipRouter: mockCCIPRouter}),
            hyperlane: HyperlaneInput({shouldDeploy: false, mailbox: address(0), ism: address(0)}),
            connections: new AdapterConnections[](0)
        });

        vm.expectRevert("Chainlink ccipRouter must be a deployed contract");
        this._validateChainlinkInputExternal(invalidInput);
    }

    // External wrapper functions to allow expectRevert to work properly (must be external)
    function _validateAxelarInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateAxelarInput(adaptersInput);
    }

    function _validateLayerZeroInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateLayerZeroInput(adaptersInput);
    }

    function _validateChainlinkInputExternal(AdaptersInput memory adaptersInput) external view {
        _validateChainlinkInput(adaptersInput);
    }
}
