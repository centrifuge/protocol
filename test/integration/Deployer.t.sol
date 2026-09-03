// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";

import {Root} from "../../src/admin/Root.sol";
import {ISafe} from "../../src/admin/interfaces/ISafe.sol";

import {DeployPhase} from "../../script/deploy/GatedDeployer.s.sol";
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
} from "../../script/deploy/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {RootFixes} from "../../src/deployment/RootFixes.sol";
import {CoreReport, CoreActionBatcher, RootAccessMismatch} from "../../src/deployment/ActionBatchers.sol";
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

    uint256 internal constant MAINNET_DELAY = 48 hours;

    uint16 internal centrifugeId_ = CENTRIFUGE_ID;
    address internal namespace_;

    /// @dev What a launch is handed. Zero root means it deploys its own; the subclasses below vary them
    address internal existingRoot_;
    uint256 internal delay_ = MAINNET_DELAY;

    /// @dev Mock deployed code for validation check which requires deployed code length > 0
    function _mockBridgeContracts() internal {
        vm.etch(AXELAR_GATEWAY, SIMPLE_CONTRACT);
        vm.etch(AXELAR_GAS_SERVICE, SIMPLE_CONTRACT);
        vm.etch(CHAINLINK_CCIP_ROUTER, SIMPLE_CONTRACT);
        vm.etch(HYPERLANE_MAILBOX, SIMPLE_CONTRACT);
    }

    function setUp() public virtual {
        _mockBridgeContracts();

        // Both phases in one go, through a gate this contract administers and executes
        _bootstrap();
        deployFullBothPhases(_input(""), namespace_, _executors(address(this)));
    }

    /// @dev The gate is brought up by the deployment itself, so there is nothing to place first. This
    ///      contract owns the namespace it deploys under because it is the one that commits in it
    function _bootstrap() internal {
        namespace_ = address(this);
    }

    /// @dev Deployed by whoever is named here, in the namespace this contract commits in
    function _executors(address executor_) internal pure returns (address[] memory executors) {
        executors = new address[](1);
        executors[0] = executor_;
    }

    function _input(string memory deploymentId_) internal view returns (DeployerInput memory) {
        return DeployerInput({
            centrifugeId: centrifugeId_,
            deploymentId: deploymentId_,
            txLimits: defaultTxLimits(),
            protocolSafe: ADMIN_SAFE,
            opsSafe: OPS_SAFE,
            root: existingRoot_,
            delay: delay_,
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
        });
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

        assertEq(messageDispatcher.wards(address(root)), 1);
        assertEq(messageDispatcher.wards(address(protocolGuardian)), 1);
        assertEq(messageDispatcher.wards(address(spoke)), 1);
        assertEq(messageDispatcher.wards(address(hub)), 1);
        assertEq(messageDispatcher.wards(address(hubHandler)), 1);
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

        assertEq(spoke.wards(address(root)), 1);
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
        vm.assume(nonWard != address(spokeRegistry));

        assertEq(shareTokenRegistrar.wards(address(root)), 1);
        assertEq(shareTokenRegistrar.wards(address(spokeHandler)), 1);
        assertEq(shareTokenRegistrar.wards(address(spoke)), 1);
        assertEq(shareTokenRegistrar.wards(address(spokeRegistry)), 1);
        assertEq(shareTokenRegistrar.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(shareTokenRegistrar.root()), address(root));
        assertEq(address(shareTokenRegistrar.envoy()), address(envoy));
        assertEq(address(shareTokenRegistrar.spokeRegistry()), address(spokeRegistry));
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
        assertEq(address(protocolGuardian.tokenBridge()), address(tokenBridge));
    }

    function testOpsGuardian() public view {
        // dependencies set correctly
        assertEq(address(opsGuardian.opsSafe()), address(OPS_SAFE));
        assertEq(address(opsGuardian.multiAdapter()), address(multiAdapter));
        assertEq(address(opsGuardian.hub()), address(hub));
        assertEq(address(opsGuardian.tokenBridge()), address(tokenBridge));
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

        assertEq(asyncRequestManager.wards(address(root)), 1);
        assertEq(asyncRequestManager.wards(address(spokeHandler)), 1);
        assertEq(asyncRequestManager.wards(address(syncDepositVaultFactory)), 1);
        assertEq(asyncRequestManager.wards(address(asyncVaultFactory)), 1);
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
        assertEq(refundEscrowFactory.root(), address(root));
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
        assertEq(address(freezeOnlyHook.poolEscrowProvider()), address(poolEscrowFactory));
        assertFalse(freezeOnlyHook.isPoolEscrow(nonWard));
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
        assertEq(address(redemptionRestrictionsHook.poolEscrowProvider()), address(poolEscrowFactory));
        assertFalse(redemptionRestrictionsHook.isPoolEscrow(nonWard));
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
        assertEq(address(freelyTransferableHook.poolEscrowProvider()), address(poolEscrowFactory));
        assertFalse(freelyTransferableHook.isPoolEscrow(nonWard));
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
        assertEq(address(fullRestrictionsHook.poolEscrowProvider()), address(poolEscrowFactory));
        assertFalse(fullRestrictionsHook.isPoolEscrow(nonWard));
    }

    function testOnOffRampFactory() public view {
        // dependencies set correctly
        assertEq(address(onOffRampFactory.envoy()), address(envoy));
        assertEq(address(onOffRampFactory.spoke()), address(spoke));
        assertEq(address(onOffRampFactory.accountingToken()), address(accountingToken));
    }

    function testShareManager() public view {
        // dependencies set correctly
        assertEq(address(shareManager.envoy()), address(envoy));
        assertEq(address(shareManager.spoke()), address(spoke));
        assertEq(address(shareManager.spokeRegistry()), address(spokeRegistry));

        // root endorsements
        assertEq(root.endorsed(address(shareManager)), true);
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

        assertEq(batchRequestManager.wards(address(root)), 1);
        assertEq(batchRequestManager.wards(address(hub)), 1);
        assertEq(batchRequestManager.wards(address(hubHandler)), 1);
        assertEq(batchRequestManager.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(batchRequestManager.envoy(), address(envoy));
    }

    function testOnchainPMFactory() public view {
        // dependencies set correctly
        assertEq(onchainPMFactory.envoy(), address(envoy));
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
        assertEq(bridgeCircuitBreaker.wards(address(hubHandler)), 1);
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

    function testTokenBridge(address nonWard) public view {
        // permissions set correctly
        vm.assume(nonWard != address(root));
        vm.assume(nonWard != address(protocolGuardian));
        vm.assume(nonWard != address(opsGuardian));

        assertEq(tokenBridge.wards(address(root)), 1);
        assertEq(tokenBridge.wards(address(protocolGuardian)), 1);
        assertEq(tokenBridge.wards(address(opsGuardian)), 1);
        assertEq(tokenBridge.wards(nonWard), 0);

        // dependencies set correctly
        assertEq(address(tokenBridge.spoke()), address(spoke));
        assertEq(address(tokenBridge.gateway()), address(gateway));
        assertEq(address(tokenBridge.envoy()), address(envoy));
        assertEq(address(opsGuardian.tokenBridge()), address(tokenBridge));

        // root endorsements
        assertEq(root.endorsed(address(tokenBridge)), true);
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
        assertEq(adapterFailover.timelock(), uint64(MAINNET_DELAY));
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

/// @dev Deploying through the DeployGate must produce the very same deployment, only signed differently
///      and at different addresses
contract FullDeploymentGatedTest is FullDeploymentConfigTest {
    function testEverythingWentThroughTheDeployGate() public view {
        assertGt(deployedContracts, 50, "the whole protocol should go through the DeployGate");
    }

    /// @dev The commitment is the whole of the gate's state, so a spent one leaves an executor nothing to
    ///      deploy with, on this namespace or any other
    function testTheCommitmentIsSpent() public view {
        (,, uint64 cursor,) = deployGate.commitments(namespace_, DEFAULT_COMMITMENT_ID);
        assertEq(cursor, deployedContracts, "every committed contract was deployed");
        assertEq(
            deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("root", V3_3)),
            0,
            "and nothing is left to deploy"
        );
    }

    function testEveryContractIsDeployed() public view {
        assertGt(address(deployGate).code.length, 0, "deployGate");
        assertGt(address(root).code.length, 0, "root");
        assertGt(address(spoke).code.length, 0, "spoke");
        assertGt(address(hub).code.length, 0, "hub");
        assertGt(address(coreBatcher).code.length, 0, "coreBatcher");
        assertGt(address(nonCoreBatcher).code.length, 0, "nonCoreBatcher");
        assertGt(address(adapterBatcher).code.length, 0, "adapterBatcher");
        assertGt(address(layerZeroAdapter).code.length, 0, "layerZeroAdapter");
    }

    /// @dev The DeployGate deploys, it never wires. A leaked key must not reach a live deployment.
    function testDeployGateHasNoPermissions() public view {
        address deployGate_ = address(deployGate);

        assertEq(root.wards(deployGate_), 0, "root");
        assertEq(gateway.wards(deployGate_), 0, "gateway");
        assertEq(multiAdapter.wards(deployGate_), 0, "multiAdapter");
        assertEq(spoke.wards(deployGate_), 0, "spoke");
        assertEq(spokeRegistry.wards(deployGate_), 0, "spokeRegistry");
        assertEq(hub.wards(deployGate_), 0, "hub");
        assertEq(hubRegistry.wards(deployGate_), 0, "hubRegistry");
        assertEq(shareTokenRegistrar.wards(deployGate_), 0, "shareTokenRegistrar");
        assertEq(asyncRequestManager.wards(deployGate_), 0, "asyncRequestManager");
        assertEq(tokenBridge.wards(deployGate_), 0, "tokenBridge");
    }

    /// @dev The registry reports what was deployed, once each. The commit phase registers addresses as it
    ///      walks, and the state rollback that ends it is what discards them again, this script's own storage
    ///      being rolled back along with everything else
    /// @dev The three action batchers are deployed but not reported: they hold no permission once they have
    ///      wired the protocol, and nothing ever reads one back, so they do not belong in `env/<environment>/<network>.json`
    function testReportsEveryContractButTheBatchers() public view {
        assertEq(registeredCount() + 3, deployedContracts, "the registry should report every other contract");

        assertFalse(_registered("coreBatcher"), "coreBatcher is not reported");
        assertFalse(_registered("nonCoreBatcher"), "nonCoreBatcher is not reported");
        assertFalse(_registered("adapterBatcher"), "adapterBatcher is not reported");
    }

    /// @dev Nothing stays committed once deployed, so a stale approval cannot linger on chain
    function testCommitmentsAreConsumed() public view {
        assertEq(deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("root", V3_3)), 0, "root");
        assertEq(deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("spoke", V3_3)), 0, "spoke");
        assertEq(
            deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("coreBatcher", V_LATEST)),
            0,
            "coreBatcher"
        );
    }

    /// @dev Wiring depends on the addresses predicted while queueing, so a mismatch would show up here
    function testWiringUsesThePredictedAddresses() public view {
        assertEq(address(gateway.processor()), address(messageProcessor));
        assertEq(address(gateway.adapter()), address(multiAdapter));
        assertEq(address(spoke.sender()), address(messageDispatcher));
        assertEq(address(hub.sender()), address(messageDispatcher));
        assertEq(address(hubHandler.sender()), address(messageDispatcher));
        assertEq(address(messageDispatcher.spokeHandler()), address(spokeHandler));
        assertEq(address(messageProcessor.hubHandler()), address(hubHandler));
        assertEq(address(poolEscrowFactory.spoke()), address(spoke));
        assertEq(address(protocolGuardian.safe()), address(ADMIN_SAFE));
        assertEq(address(opsGuardian.opsSafe()), address(OPS_SAFE));

        assertEq(gateway.wards(address(root)), 1);
        assertEq(hub.wards(address(hubHandler)), 1);
        assertEq(spokeRegistry.wards(address(spoke)), 1);
        assertEq(root.wards(address(messageDispatcher)), 1);
        assertTrue(root.endorsements(address(spoke)) == 1);

        assertEq(hubRegistry.decimals(USD_ID), ISO4217_DECIMALS);
        assertEq(hubRegistry.decimals(EUR_ID), ISO4217_DECIMALS);
    }

    /// @dev The action batchers must give up their permissions, exactly as in a direct deployment
    function testActionBatchersRevokedThemselves() public view {
        assertEq(root.wards(address(coreBatcher)), 0, "coreBatcher on root");
        assertEq(gateway.wards(address(coreBatcher)), 0, "coreBatcher on gateway");
        assertEq(hub.wards(address(coreBatcher)), 0, "coreBatcher on hub");
        assertEq(spoke.wards(address(coreBatcher)), 0, "coreBatcher on spoke");
        assertEq(root.wards(address(nonCoreBatcher)), 0, "nonCoreBatcher on root");
        assertEq(multiAdapter.wards(address(adapterBatcher)), 0, "multiAdapter on adapterBatcher");
    }
}

/// @dev The point of the design: the admin signs a single transaction, and nothing but what it committed to
///      can then be deployed
contract FullDeploymentPhasedTest is FullDeploymentConfigTest {
    address immutable EXECUTOR = makeAddr("executor");

    function setUp() public virtual override {
        _mockBridgeContracts();
        _bootstrap();

        // The phases are signed by different accounts on a real deployment, so the fixture separates them too.
        // Running both as one account would hide an init code that depends on who is deploying: it would come
        // out the same in both walks here, and only revert with `NotCommitted` on chain, after the signature.
        // Naming the executor is the commit phase's job, so nothing has to be granted before it
        _deploy(DeployPhase.Commit);
    }

    /// @dev One phase at a time, unlike the base fixture, which runs both, and each as the account that signs
    ///      it: the admin commits, an executor that is a ward of nothing deploys
    function _deploy(DeployPhase phase) internal {
        _deploy(phase, "");
    }

    function _deploy(DeployPhase phase, string memory deploymentId_) internal {
        if (phase == DeployPhase.Commit) {
            deployFull(_input(deploymentId_), phase, namespace_, _executors(EXECUTOR));
            return;
        }

        vm.startPrank(EXECUTOR);
        deployFull(_input(deploymentId_), phase, namespace_, _executors(EXECUTOR));
        vm.stopPrank();
    }

    function testCommitPhaseDeploysNothingButTheDeployGate() public view {
        assertGt(address(deployGate).code.length, 0, "deployGate");
        assertEq(address(root).code.length, 0, "root");
        assertEq(address(spoke).code.length, 0, "spoke");
        assertEq(deployedContracts, 0);
    }

    function testCommitPhaseCommitsEveryContract() public view virtual {
        assertGt(committedContracts, 50, "the admin should commit the whole protocol in one transaction");
        assertTrue(deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("root", V3_3)) != 0, "root");
        assertTrue(deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("spoke", V3_3)) != 0, "spoke");
        assertTrue(deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("hub", V3_3)) != 0, "hub");
        assertTrue(
            deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("coreBatcher", V_LATEST)) != 0,
            "coreBatcher"
        );
        assertTrue(
            deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("neverDeployed", V3_3)) == 0,
            "unknown salt"
        );
    }

    function testExecutorCanOnlyDeployWhatWasCommitted() public {
        assertTrue(
            deployGate.isExecutor(namespace_, DEFAULT_COMMITMENT_ID, EXECUTOR),
            "the executor may deploy what was committed"
        );
        assertFalse(
            deployGate.isExecutor(namespace_, DEFAULT_COMMITMENT_ID, address(this)),
            "the namespace is not the one deploying"
        );

        _deploy(DeployPhase.Deploy);

        // Same deployment a single signer would have produced
        assertGt(deployedContracts, 50);
        assertEq(address(spoke.sender()), address(messageDispatcher));
        assertEq(address(protocolGuardian.safe()), address(ADMIN_SAFE));
        assertEq(gateway.wards(address(root)), 1);
        assertEq(root.wards(address(coreBatcher)), 0, "coreBatcher should have revoked itself");
        assertEq(root.wards(address(deployGate)), 0, "the gate must gain nothing");
        assertEq(root.wards(EXECUTOR), 0, "nor the executor that deployed it");
        assertEq(hubRegistry.decimals(USD_ID), ISO4217_DECIMALS);
    }

    /// @dev Deploying needs a commitment, so the executor cannot deploy a set the admin never committed to.
    ///      Caught before anything is broadcast, the DeployGate itself being the backstop.
    /// @dev The guard trips on the first contract, before the gate is called at all, so this runs from here
    ///      rather than under a prank, which expectRevert needs anyway
    function testExecutorCannotDeployWhatWasNotCommitted() public {
        vm.expectRevert("Deployment does not match what was committed, commit again");
        this.deployUncommitted();
    }

    /// @dev The same protocol under another deployment id, through the same gate: nothing here was ever committed
    function deployUncommitted() external {
        _deploy(DeployPhase.Deploy, "uncommitted");
    }
}

/// @dev Launching onto a chain that already carries a Root: it is kept rather than replaced, and the wiring
///      only Root can do waits for `RootFixes`, since the action batchers are wards of nothing on it
contract FullDeploymentExistingRootTest is FullDeploymentConfigTest {
    Root internal priorRoot;

    function setUp() public override {
        // Stands for the Root a previous release left on the chain, this contract being its governance
        priorRoot = new Root(MAINNET_DELAY, address(this));
        existingRoot_ = address(priorRoot);

        super.setUp();
    }

    function testKeepsTheRootItWasGiven() public view {
        assertEq(address(root), address(priorRoot), "the deployment should not have deployed a second Root");
        assertEq(root.wards(address(this)), 1, "the Root it was given keeps its own wards");
    }

    /// @dev Everything not reaching into Root is wired as usual, batcher wards and all
    function testTheRestOfTheDeploymentIsUnchanged() public view {
        assertEq(gateway.wards(address(root)), 1, "root on gateway");
        assertEq(hub.wards(address(hubHandler)), 1, "hubHandler on hub");
        assertEq(address(spoke.sender()), address(messageDispatcher));
        assertEq(gateway.wards(address(coreBatcher)), 0, "coreBatcher should have revoked itself");
        assertEq(hubRegistry.decimals(USD_ID), ISO4217_DECIMALS);
    }

    /// @dev Deploy-time only, like the action batchers, so it stays out of `env/<network>.json`. The Root it
    ///      wires does belong there, at the address it already had
    function testRootIsRecordedAndRootFixesIsNot() public view {
        assertTrue(_registered("root"), "root");
        assertFalse(_registered("rootFixes"), "rootFixes");
    }

    /// @dev The batchers cannot touch a Root that does not ward them, so they must not have tried
    function testRootWiringIsLeftUndone() public view {
        assertEq(root.wards(address(messageDispatcher)), 0, "messageDispatcher on root");
        assertEq(root.wards(address(messageProcessor)), 0, "messageProcessor on root");
        assertEq(root.wards(address(protocolGuardian)), 0, "protocolGuardian on root");
        assertEq(root.wards(address(coreBatcher)), 0, "coreBatcher on root");
        assertEq(root.wards(address(nonCoreBatcher)), 0, "nonCoreBatcher on root");
        assertFalse(root.endorsed(address(spoke)), "spoke endorsed");
        assertFalse(root.endorsed(address(asyncRequestManager)), "asyncRequestManager endorsed");
        assertFalse(root.endorsed(address(shareManager)), "shareManager endorsed");
    }

    /// @dev What the batchers left, done under a ward governance grants through the ordinary timelock
    function testRootFixesFinishesTheWiring() public {
        assertEq(address(rootFixes.root()), address(root), "rootFixes should point at the Root in use");

        priorRoot.scheduleRely(address(rootFixes));
        vm.warp(block.timestamp + MAINNET_DELAY);
        priorRoot.executeScheduledRely(address(rootFixes));

        rootFixes.cast();

        // Exactly what a deployment that brought its own Root up ends with
        assertEq(root.wards(address(messageDispatcher)), 1, "messageDispatcher on root");
        assertEq(root.wards(address(messageProcessor)), 1, "messageProcessor on root");
        assertEq(root.wards(address(protocolGuardian)), 1, "protocolGuardian on root");
        assertTrue(root.endorsed(address(spoke)), "spoke endorsed");
        assertTrue(root.endorsed(address(asyncRequestManager)), "asyncRequestManager endorsed");
        assertTrue(root.endorsed(address(vaultRouter)), "vaultRouter endorsed");
        assertTrue(root.endorsed(address(tokenBridge)), "tokenBridge endorsed");
        assertTrue(root.endorsed(address(shareManager)), "shareManager endorsed");

        // And it gives the ward back, as the batchers do
        assertTrue(rootFixes.done());
        assertEq(root.wards(address(rootFixes)), 0, "rootFixes should have revoked itself");
    }

    function testRootFixesNeedsItsWard() public {
        vm.expectRevert(IAuth.NotAuthorized.selector);
        rootFixes.cast();
    }

    function testRootFixesCastsOnce() public {
        priorRoot.scheduleRely(address(rootFixes));
        vm.warp(block.timestamp + MAINNET_DELAY);
        priorRoot.executeScheduledRely(address(rootFixes));

        rootFixes.cast();

        vm.expectRevert(RootFixes.AlreadyCast.selector);
        rootFixes.cast();
    }
}

/// @dev The phases apart, over an existing Root: what the validate phase commits has to be exactly what the
///      execute phase rebuilds, and Root is a constructor argument of nearly everything in it
contract ExistingRootPhasedTest is FullDeploymentPhasedTest {
    Root internal priorRoot;

    function setUp() public override {
        priorRoot = new Root(MAINNET_DELAY, address(this));
        existingRoot_ = address(priorRoot);

        super.setUp();
    }

    /// @dev The base fixture's, less the Root this chain already carries — which is not part of the
    ///      commitment, nothing here deploying it — plus the `RootFixes` that stands in for it
    function testCommitPhaseCommitsEveryContract() public view override {
        assertGt(committedContracts, 50, "the admin should commit the whole protocol in one transaction");
        assertTrue(deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("spoke", V3_3)) != 0, "spoke");
        assertTrue(deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("hub", V3_3)) != 0, "hub");
        assertTrue(
            deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("rootFixes", V_LATEST)) != 0, "rootFixes"
        );
        assertTrue(
            deployGate.committed(namespace_, DEFAULT_COMMITMENT_ID, _gatedSalt("root", V3_3)) == 0,
            "the Root already on the chain is not committed to"
        );
    }

    /// @dev The one address a committing run has to be able to name, its walk having been rolled back
    function testCommitPhaseStillNamesRootFixes() public view {
        assertEq(address(rootFixes), gatedAddressOf("rootFixes"), "carried across the rollback");
        assertEq(address(rootFixes).code.length, 0, "but nothing is deployed there yet");
        assertEq(address(root), address(0), "the rest of the walk is gone");
    }

    function gatedAddressOf(string memory name) internal view returns (address) {
        return deployGate.addressOf(namespace_, _gatedSalt(name, V_LATEST));
    }

    function testDeployPhaseRebuildsWhatWasCommitted() public {
        _deploy(DeployPhase.Deploy);

        assertEq(address(root), address(priorRoot), "the Root it was given");
        assertGt(address(rootFixes).code.length, 0, "rootFixes");
        assertEq(address(spoke.sender()), address(messageDispatcher));
        assertEq(gateway.wards(address(root)), 1, "root on gateway");
        assertEq(root.wards(address(messageDispatcher)), 0, "root wiring waits for rootFixes");
    }
}

/// @dev The flag and the ward it implies have to agree, or the batcher stops the deployment. Unreachable
///      through `FullDeployer`, which derives the flag from the same `input.root`, and asserted because the
///      wrong pairing is silent: skipping the wiring while holding the ward leaves the batcher a ward of Root
contract ActionBatcherRootAccessTest is Test {
    function testWiringARootItIsNoWardOfReverts() public {
        Root root = new Root(48 hours, makeAddr("someoneElse"));

        vm.expectRevert(RootAccessMismatch.selector);
        new CoreActionBatcher(_report(root), ISafe(address(0)), ISafe(address(0)), address(0), address(0), true);
    }

    function testSkippingARootItIsAWardOfReverts() public {
        // Warded, as a freshly deployed Root wards the batcher that deployed it
        Root root = new Root(48 hours, _batcherAddress());

        vm.expectRevert(RootAccessMismatch.selector);
        new CoreActionBatcher(_report(root), ISafe(address(0)), ISafe(address(0)), address(0), address(0), false);
    }

    /// @dev Where the next `new CoreActionBatcher` in this contract lands, so the Root above can ward it
    function _batcherAddress() private view returns (address) {
        return vm.computeCreateAddress(address(this), vm.getNonce(address(this)) + 1);
    }

    function _report(Root root) private pure returns (CoreReport memory report) {
        report.root = root;
    }
}

/// @dev A kept Root keeps its own delay, so `AdapterFailover` has to follow that rather than the input, or
///      the two disagree about what the protocol delay is
contract FullDeploymentKeptRootDelayTest is FullDeploymentConfigTest {
    uint256 constant PRIOR_DELAY = 6 hours;

    function setUp() public override {
        existingRoot_ = address(new Root(PRIOR_DELAY, address(this)));
        delay_ = MAINNET_DELAY;

        super.setUp();
    }

    function testAdapterFailoverFollowsTheKeptRoot() public view {
        assertEq(root.delay(), PRIOR_DELAY, "the input delay must not touch a kept Root");
        assertEq(adapterFailover.timelock(), uint64(PRIOR_DELAY));
    }
}

/// @dev What everything off mainnet deploys: no timelock, so a spell casts in the block it was scheduled in
contract FullDeploymentNoDelayTest is FullDeploymentConfigTest {
    function setUp() public override {
        delay_ = 0;

        super.setUp();
    }

    function testRootCarriesNoDelay() public view {
        assertEq(root.delay(), 0);
        assertEq(adapterFailover.timelock(), 0, "AdapterFailover should match the protocol delay");
    }

    function testASpellIsRelyableAtOnce() public {
        address spell = makeAddr("spell");

        vm.prank(address(ADMIN_SAFE));
        protocolGuardian.scheduleRely(spell);

        root.executeScheduledRely(spell);

        assertEq(root.wards(spell), 1);
    }

    /// @dev The delay is init code, which CREATE3 does not look at
    function testTheDelayMovesNoAddress() public {
        assertEq(address(root), gatedAddress("root", V3_3));
        assertEq(address(adapterFailover), gatedAddress("adapterFailover", V3_3));
    }
}
