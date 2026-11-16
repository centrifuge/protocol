// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {LocalAdapter} from "./adapters/LocalAdapter.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {D18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../src/misc/libraries/MathLib.sol";
import {IERC8161RedeemTransferable} from "../../src/misc/interfaces/IERC8161.sol";

import {Hub} from "../../src/core/hub/Hub.sol";
import {Spoke} from "../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../src/core/types/PoolId.sol";
import {Holdings} from "../../src/core/hub/Holdings.sol";
import {IHub} from "../../src/core/hub/interfaces/IHub.sol";
import {AccountId} from "../../src/core/types/AccountId.sol";
import {Accounting} from "../../src/core/hub/Accounting.sol";
import {Gateway} from "../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../src/core/hub/HubHandler.sol";
import {RequestId} from "../../src/core/types/RequestId.sol";
import {HubRegistry} from "../../src/core/hub/HubRegistry.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {PricingLib} from "../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {SpokeHandler} from "../../src/core/spoke/SpokeHandler.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {SpokeRegistry} from "../../src/core/spoke/SpokeRegistry.sol";
import {ISpokePolicy} from "../../src/core/utils/interfaces/IPolicy.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {ShareClassManager} from "../../src/core/hub/ShareClassManager.sol";
import {ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromSpoke} from "../../src/core/utils/interfaces/IManagerCall.sol";
import {IHubRequestManager} from "../../src/core/hub/interfaces/IHubRequestManager.sol";
import {MultiAdapter, MAX_ADAPTER_COUNT} from "../../src/core/messaging/MultiAdapter.sol";
import {ILocalCentrifugeId} from "../../src/core/messaging/interfaces/IGatewaySenders.sol";
import {MessageLib, MessageType, VaultUpdateKind, ManagerKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {VaultRequestRouter} from "../../src/vaults/messaging/VaultRequestRouter.sol";

import {Root} from "../../src/admin/Root.sol";
import {GasService} from "../../src/admin/GasService.sol";
import {ISafe} from "../../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../src/admin/ProtocolGuardian.sol";

import {MockSnapshotHook} from "../hooks/mocks/MockSnapshotHook.sol";

import {ShareTokenHook} from "../../src/token/hooks/ShareTokenHook.sol";
import {UpdateRestrictionMessageLib} from "../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {QueueManager} from "../../src/managers/spoke/QueueManager.sol";
import {ShareManager} from "../../src/managers/spoke/ShareManager.sol";
import {IShareManager} from "../../src/managers/spoke/interfaces/IShareManager.sol";

import {OracleValuation} from "../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../src/valuations/IdentityValuation.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {OrderBook} from "../../src/vaults/hub/OrderBook.sol";
import {VaultRouter} from "../../src/vaults/VaultRouter.sol";
import {SpokeOracle} from "../../src/vaults/oracles/SpokeOracle.sol";
import {VaultFactory} from "../../src/vaults/factories/VaultFactory.sol";
import {FeeRequestManager} from "../../src/vaults/hub/FeeRequestManager.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {IAsyncVault, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {ReserveInstantPolicy} from "../../src/vaults/policies/ReserveInstantPolicy.sol";
import {PerInvestorPolicy, PerPeriodPolicy, PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {
    IInstantPolicy,
    ILiquidityRoute,
    ISettlementObserver,
    IReserveInstantPolicy
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {FullDeployer, DeployerInput, noAdaptersInput, defaultTxLimits} from "../../script/deploy/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {MAX_MESSAGE_COST} from "../utils/GasConstants.sol";
import {USD_ID} from "../../src/deployment/Currencies.sol";
import {SubsidyManager} from "../../src/utils/SubsidyManager.sol";
import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";
import {ITransferHook} from "../../src/token/interfaces/ITransferHook.sol";
import {RefundEscrowFactory} from "../../src/utils/RefundEscrowFactory.sol";
import {ShareTokenRegistrar} from "../../src/token/ShareTokenRegistrar.sol";
import {IShareTokenRegistrar} from "../../src/token/interfaces/IShareTokenRegistrar.sol";

/// End to end testing assuming two full deployments in two different chains
///
/// This EndToEnd tests emulates two chains fully deployed and connected through an adapter
/// Each test case can receive a fuzzed boolean parameter to be tested in both cases:
/// - If sameChain: hub is in CENTRIFUGE_ID_A and spoke is in CENTRIFUGE_ID_A
/// - If !sameChain: hub is in CENTRIFUGE_ID_A and spoke is in CENTRIFUGE_ID_B
///
/// NOTE: All contracts used needs to be placed in the below structs to avoid external calls each time a contract is
/// chosen from a deployment. If not, it has two side effects:
///   1.
///   vm.prank(FM)
///   deployA.hub().notifyPool() // Will fail, given prank is used to retrieve the hub.
///
///   2. It significantly increases the amount of calls shown by the debugger.
///
/// By using these structs we avoid both "issues".
contract EndToEndDeployment is Test {
    using MathLib for *;
    using CastLib for *;
    using PricingLib for *;

    struct CHub {
        uint16 centrifugeId;
        // Core
        Gateway gateway;
        MultiAdapter multiAdapter;
        GasService gasService;
        // Admin
        Root root;
        ProtocolGuardian protocolGuardian;
        OpsGuardian opsGuardian;
        // Hub
        HubRegistry hubRegistry;
        Accounting accounting;
        Holdings holdings;
        ShareClassManager shareClassManager;
        Hub hub;
        HubHandler hubHandler;
        // Others
        IdentityValuation identityValuation;
        OracleValuation oracleValuation;
        MockSnapshotHook snapshotHook;
        // Vaults (hub side)
        OrderBook orderBook;
        FeeRequestManager feeRequestManager;
    }

    struct CSpoke {
        uint16 centrifugeId;
        // Core
        Gateway gateway;
        MultiAdapter multiAdapter;
        // Admin
        Root root;
        ProtocolGuardian protocolGuardian;
        OpsGuardian opsGuardian;
        // Spoke
        Spoke spoke;
        SpokeRegistry spokeRegistry;
        SpokeHandler spokeHandler;
        ShareTokenRegistrar shareTokenRegistrar;
        SubsidyManager subsidyManager;
        QueueManager queueManager;
        RefundEscrowFactory refundEscrowFactory;
        // Managers
        ShareManager shareManager;
        // Hooks
        ShareTokenHook freezeOnlyHook;
        ShareTokenHook fullRestrictionsHook;
        ShareTokenHook redemptionRestrictionsHook;
        // Others
        ERC20 usdc;
        AssetId usdcId;
        // Vaults (spoke side)
        VaultFactory vaultFactory;
        VaultRequestRouter vaultRequestRouter;
        VaultRouter vaultRouter;
        PerRequestPolicy perRequestPolicy;
        PerInvestorPolicy perInvestorPolicy;
        SpokeOracle spokeOracle;
        ReserveInstantPolicy reserveInstantPolicy;
    }

    ISafe immutable SAFE_ADMIN_A = ISafe(makeAddr("SafeAdminA"));
    ISafe immutable SAFE_ADMIN_B = ISafe(makeAddr("SafeAdminB"));

    uint16 constant CENTRIFUGE_ID_A = IntegrationConstants.CENTRIFUGE_ID_A;
    uint16 constant CENTRIFUGE_ID_B = IntegrationConstants.CENTRIFUGE_ID_B;
    uint128 constant GAS = MAX_MESSAGE_COST;
    uint256 constant DEFAULT_SUBSIDY = IntegrationConstants.DEFAULT_SUBSIDY;
    uint128 constant HOOK_GAS = IntegrationConstants.HOOK_GAS;

    address immutable ERC20_DEPLOYER = address(this);
    address immutable FM = makeAddr("FM"); // Or pool manager
    address immutable BSM = makeAddr("BSM");
    address immutable FEEDER = makeAddr("FEEDER");
    address immutable INVESTOR_A = makeAddr("INVESTOR_A");
    address immutable ANY = makeAddr("ANY");
    address immutable GATEWAY_MANAGER = makeAddr("GATEWAY_MANAGER");
    address immutable REFUND = makeAddr("REFUND");

    uint128 constant USDC_AMOUNT_1 = IntegrationConstants.DEFAULT_USDC_AMOUNT;

    AccountId constant ASSET_ACCOUNT = IntegrationConstants.ASSET_ACCOUNT;
    AccountId constant EQUITY_ACCOUNT = IntegrationConstants.EQUITY_ACCOUNT;
    AccountId constant LOSS_ACCOUNT = IntegrationConstants.LOSS_ACCOUNT;
    AccountId constant GAIN_ACCOUNT = IntegrationConstants.GAIN_ACCOUNT;

    PoolId constant GLOBAL_POOL = PoolId.wrap(0);

    PoolId POOL_A;
    ShareClassId SC_1;

    FullDeployer deployA = new FullDeployer();
    FullDeployer deployB = new FullDeployer();

    LocalAdapter adapterAToB;
    LocalAdapter adapterBToA;

    LocalAdapter poolAdapterHToS;
    LocalAdapter poolAdapterSToH;

    CHub h;
    CSpoke s;

    uint8 constant USDC_DECIMALS = IntegrationConstants.USDC_DECIMALS;
    uint8 constant POOL_DECIMALS = IntegrationConstants.POOL_DECIMALS;
    uint8 constant SHARE_DECIMALS = POOL_DECIMALS;

    uint256 constant PLACEHOLDER_REQUEST_ID = IntegrationConstants.PLACEHOLDER_REQUEST_ID;
    uint128 constant EXTRA_GAS = IntegrationConstants.EXTRA_GAS;
    uint128 constant SHARE_REVOKE_EXTRA_GAS = IntegrationConstants.SHARE_REVOKE_EXTRA_GAS;

    // Set by _configurePrices and read by pricing utilities
    D18 currentAssetPrice = IntegrationConstants.identityPrice();
    D18 currentSharePrice = IntegrationConstants.identityPrice();

    bool constant IN_DIFFERENT_CHAINS = false;

    //----------------------------------------------------------------------------------------------
    // Test Setup & Infrastructure
    //----------------------------------------------------------------------------------------------

    function setUp() public virtual {
        // Wire global adapters
        adapterAToB = _deployChain(deployA, CENTRIFUGE_ID_A, CENTRIFUGE_ID_B, SAFE_ADMIN_A);
        adapterBToA = _deployChain(deployB, CENTRIFUGE_ID_B, CENTRIFUGE_ID_A, SAFE_ADMIN_B);

        adapterAToB.setEndpoint(adapterBToA);
        adapterBToA.setEndpoint(adapterAToB);

        // Initialize accounts
        vm.deal(FM, 1 ether);
        vm.deal(BSM, 1 ether);
        vm.deal(INVESTOR_A, 1 ether);
        vm.deal(ANY, 1 ether);
        vm.deal(address(SAFE_ADMIN_A), 1 ether);
        vm.deal(address(SAFE_ADMIN_B), 1 ether);

        h = CHub({
            centrifugeId: CENTRIFUGE_ID_A,
            root: deployA.root(),
            protocolGuardian: deployA.protocolGuardian(),
            opsGuardian: deployA.opsGuardian(),
            gateway: deployA.gateway(),
            multiAdapter: deployA.multiAdapter(),
            gasService: deployA.gasService(),
            hubRegistry: deployA.hubRegistry(),
            accounting: deployA.accounting(),
            holdings: deployA.holdings(),
            shareClassManager: deployA.shareClassManager(),
            hub: deployA.hub(),
            hubHandler: deployA.hubHandler(),
            identityValuation: deployA.identityValuation(),
            oracleValuation: deployA.oracleValuation(),
            snapshotHook: new MockSnapshotHook(),
            orderBook: deployA.orderBook(),
            feeRequestManager: deployA.feeRequestManager()
        });

        // Initialize default values
        POOL_A = h.hubRegistry.poolId(CENTRIFUGE_ID_A, 1);
        SC_1 = h.shareClassManager.previewNextShareClassId(POOL_A);

        vm.label(address(adapterAToB), "AdapterAToB");
        vm.label(address(adapterBToA), "AdapterBToA");

        vm.recordLogs();
    }

    function _setAdapter(FullDeployer deploy, uint16 remoteCentrifugeId, IAdapter adapter) internal {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = adapter;
        // Ward wiring for the real path is asserted in Deployer.t.sol.
        vm.startPrank(address(deploy.root()));
        deploy.multiAdapter()
            .setAdapters(
                remoteCentrifugeId,
                GLOBAL_POOL,
                adapters,
                uint8(adapters.length),
                deploy.multiAdapter().activeSessionId(remoteCentrifugeId, GLOBAL_POOL) + 1
            );

        vm.stopPrank();
    }

    function _deployChain(FullDeployer deploy, uint16 localCentrifugeId, uint16 remoteCentrifugeId, ISafe protocolSafe)
        internal
        returns (LocalAdapter adapter)
    {
        address[] memory executors = new address[](1);
        executors[0] = address(deploy);

        // The deployer is the namespace of its own namespace, and its own executor
        deploy.deployFullBothPhases(
            DeployerInput({
                centrifugeId: localCentrifugeId,
                deploymentId: string(abi.encodePacked(localCentrifugeId)),
                txLimits: defaultTxLimits(),
                protocolSafe: protocolSafe,
                opsSafe: protocolSafe,
                root: address(0),
                delay: 0,
                vaults: true,
                adapters: noAdaptersInput()
            }),
            address(deploy),
            executors
        );

        adapter = new LocalAdapter(localCentrifugeId, deploy.multiAdapter(), address(deploy));
        _setAdapter(deploy, remoteCentrifugeId, adapter);
    }

    function _setSpoke(FullDeployer deploy, uint16 centrifugeId, CSpoke storage s_) internal {
        s_.centrifugeId = centrifugeId;
        s_.root = deploy.root();
        s_.protocolGuardian = deploy.protocolGuardian();
        s_.opsGuardian = deploy.opsGuardian();
        s_.gateway = deploy.gateway();
        s_.multiAdapter = deploy.multiAdapter();
        s_.spoke = deploy.spoke();
        s_.spokeRegistry = deploy.spokeRegistry();
        s_.spokeHandler = deploy.spokeHandler();
        s_.shareTokenRegistrar = deploy.shareTokenRegistrar();
        s_.freezeOnlyHook = deploy.freezeOnlyHook();
        s_.fullRestrictionsHook = deploy.fullRestrictionsHook();
        s_.redemptionRestrictionsHook = deploy.redemptionRestrictionsHook();
        s_.subsidyManager = deploy.subsidyManager();
        s_.queueManager = deploy.queueManager();
        s_.refundEscrowFactory = deploy.refundEscrowFactory();
        s_.shareManager = deploy.shareManager();
        s_.usdc = new ERC20(6);
        s_.usdcId = newAssetId(centrifugeId, 1);

        // Vault stack: the per-network singletons the deployment brings up
        s_.vaultFactory = deploy.vaultFactory();
        s_.vaultRequestRouter = deploy.vaultRequestRouter();
        s_.vaultRouter = deploy.vaultRouter();
        s_.perRequestPolicy = deploy.perRequestPolicy();
        s_.perInvestorPolicy = deploy.perInvestorPolicy();
        // Bounded to a day on both sides, so the end-to-end flows exercise the checked path
        s_.spokeOracle = deploy.spokeOracle();
        s_.reserveInstantPolicy = deploy.reserveInstantPolicy();

        // Initialize default values
        s_.usdc.file("name", "USD Coin");
        s_.usdc.file("symbol", "USDC");

        s_.subsidyManager.deposit{value: 0.5 ether}(POOL_A);
    }

    function _setSpoke(bool sameChain) internal {
        if (sameChain) {
            _setSpoke(deployA, CENTRIFUGE_ID_A, s);
        } else {
            _setSpoke(deployB, CENTRIFUGE_ID_B, s);
        }
    }
}

contract IsContract {}

/// @dev Minimal spoke-side policy for end-to-end coverage of {Spoke.enforced}. A guarded selector is
///      out of policy and must be pre-authorized (via {Hub.authorizeSpokeCall}); `enforce` consumes the
///      matured authorization from the {SpokeRegistry}. `enforce` may only be called by the enforcer (the
///      Spoke), mirroring {StdHubPolicy}'s `msg.sender == hub` gate — this is what pins the caller identity.
contract MockSpokePolicy is ISpokePolicy {
    ISpokeRegistry public immutable registry;
    address public immutable enforcer;
    bytes4 public immutable guardedSelector;

    address public lastCaller;
    uint256 public enforceCalls;

    constructor(ISpokeRegistry registry_, address enforcer_, bytes4 guardedSelector_) {
        registry = registry_;
        enforcer = enforcer_;
        guardedSelector = guardedSelector_;
    }

    function authorizationRequired(PoolId, address, bytes calldata data) external view returns (bool required) {
        // The guarded selector requires a pre-authorization; everything else runs synchronously.
        return data.length >= 4 && bytes4(data[:4]) == guardedSelector;
    }

    function enforce(PoolId poolId, address caller, bytes calldata data) external {
        require(msg.sender == enforcer, NotEnforcer());
        enforceCalls++;
        lastCaller = caller;
        if (data.length >= 4 && bytes4(data[:4]) == guardedSelector) {
            registry.consumeAuthorization(poolId, caller, data);
        }
    }
}

/// Common and generic utilities ready to be used in different tests
contract EndToEndUtils is EndToEndDeployment {
    using MathLib for *;

    function assetToShare(uint128 assetAmount) public view returns (uint128 shareAmount) {
        if (currentSharePrice.isZero()) return 0;
        return PricingLib.assetToShareAmount(
            assetAmount, USDC_DECIMALS, SHARE_DECIMALS, currentAssetPrice, currentSharePrice, MathLib.Rounding.Down
        );
    }

    function shareToAsset(uint128 shareAmount) public view returns (uint128 assetAmount) {
        if (currentAssetPrice.isZero()) return 0;
        return PricingLib.shareToAssetAmount(
            shareAmount, SHARE_DECIMALS, USDC_DECIMALS, currentSharePrice, currentAssetPrice, MathLib.Rounding.Down
        );
    }

    function assetToPool(uint128 assetAmount) public view returns (uint128 poolAmount) {
        return PricingLib.assetToPoolAmount(
            assetAmount, USDC_DECIMALS, POOL_DECIMALS, currentAssetPrice, MathLib.Rounding.Down
        );
    }

    function poolToAsset(uint128 poolAmount) public view returns (uint128 assetAmount) {
        if (currentAssetPrice.isZero()) return 0;
        return PricingLib.poolToAssetAmount(
            poolAmount, POOL_DECIMALS, USDC_DECIMALS, currentAssetPrice, MathLib.Rounding.Down
        );
    }

    function checkAccountValue(AccountId accountId, uint128 value, bool isPositive) public view {
        (bool accountIsPositive, uint128 accountValue) = h.accounting.accountValue(POOL_A, accountId);
        assertEq(accountValue, value);
        assertEq(accountIsPositive, isPositive);
    }

    function _getLastUnpaidMessage() internal returns (bytes memory message) {
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = logs.length - 1; i >= 0; i--) {
            if (logs[i].topics[0] == bytes32(IGateway.UnderpaidBatch.selector)) {
                return abi.decode(logs[i].data, (bytes));
            }
        }

        vm.recordLogs();
    }
}

/// Base investment flows that can be shared between EndToEnd tests
contract EndToEndFlows is EndToEndUtils {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;
    using MathLib for *;

    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
            user: addr.toBytes32(), validUntil: type(uint64).max
        }).serialize();
    }

    function _addMember(address addr) internal {
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(addr), EXTRA_GAS, REFUND
        );
    }

    function _updateRestrictionFreezeMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionFreeze({user: addr.toBytes32()}).serialize();
    }

    function _updateRestrictionUnfreezeMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze({user: addr.toBytes32()}).serialize();
    }

    //----------------------------------------------------------------------------------------------
    // Asset & Pool Configuration
    //----------------------------------------------------------------------------------------------

    function _createPoolAccounts() internal {
        vm.startPrank(FM);
        h.hub.createAccount(POOL_A, ASSET_ACCOUNT, true);
        h.hub.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        h.hub.createAccount(POOL_A, GAIN_ACCOUNT, false);
        h.hub.createAccount(POOL_A, LOSS_ACCOUNT, true);
        vm.stopPrank();
    }

    function _holdingAccounts(AccountId asset, AccountId equity, AccountId gain, AccountId loss)
        internal
        pure
        returns (AccountId[4] memory accounts)
    {
        accounts[0] = asset;
        accounts[1] = equity;
        accounts[2] = gain;
        accounts[3] = loss;
    }

    function _createPool() internal {
        vm.startPrank(address(h.protocolGuardian.safe()));
        h.opsGuardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32(bytes8(POOL_A.raw())));

        _createPoolAccounts();
    }

    function _configureAsset(CSpoke memory s_) internal {
        vm.startPrank(ERC20_DEPLOYER);
        s_.usdc.mint(INVESTOR_A, USDC_AMOUNT_1);

        vm.startPrank(ANY);
        s_.spoke.registerAsset{value: GAS}(h.centrifugeId, address(s_.usdc), 0, ANY);
    }

    /// @dev Sets the SC_1 hook via the registrar's Envoy path (Hub.managerCall -> registrar.fromHub).
    function _setHook(CSpoke memory s_, address hook) internal {
        bool local = s_.centrifugeId == h.centrifugeId;
        h.hub.managerCall{value: local ? 0 : GAS}(
            POOL_A,
            s_.centrifugeId,
            address(s_.shareTokenRegistrar).toBytes32(),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetHook), SC_1, hook),
            0,
            0,
            REFUND
        );
    }

    function _configurePoolInSpoke(CSpoke memory s_) internal {
        if (h.centrifugeId != s_.centrifugeId) {
            _configureBasePoolWithCustomAdapters(s_);
        }

        _configureAsset(s_);

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, s_.centrifugeId, REFUND);
        h.hub.notifyShareClass{value: GAS}(
            POOL_A, SC_1, s_.centrifugeId, address(s_.shareTokenRegistrar).toBytes32(), "", 0, REFUND
        );
        _setHook(s_, address(s_.redemptionRestrictionsHook));

        // initializeHolding now values any (zero) pre-existing amount via the valuation immediately, so it
        // cannot use the oracle valuation before a price has ever been fed (chicken-and-egg: oracleValuation's
        // setPrice() itself requires the holding to already be initialized). Start with the always-valid
        // identity valuation and switch to the oracle once a feeder is wired up below.
        h.hub
            .initializeHolding(
                POOL_A,
                SC_1,
                s_.usdcId,
                h.identityValuation,
                _holdingAccounts(ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT)
            );
        h.hub.updateManager{value: GAS}(POOL_A, s_.centrifugeId, ManagerKind.Spoke, BSM.toBytes32(), true, REFUND);

        // Requests route through the OrderBook (hub side) and the VaultRequestRouter (spoke side);
        // fulfillments run through the FeeRequestManager, itself a manager calling the Hub.
        h.hub.setRequestManager{value: GAS}(
            POOL_A,
            s_.centrifugeId,
            IHubRequestManager(address(h.orderBook)),
            address(s_.vaultRequestRouter).toBytes32(),
            REFUND
        );
        h.hub.updateHubManager(POOL_A, address(h.feeRequestManager), true);

        vm.startPrank(FM);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);
        // Feeder management is policy-supervised: route through hub.managerCall -> oracleValuation.fromHub.
        h.hub
            .managerCall(
                POOL_A,
                h.centrifugeId,
                address(h.oracleValuation).toBytes32(),
                abi.encode(uint16(0), FEEDER.toBytes32(), true),
                0,
                0,
                REFUND
            );
        h.hub.updateHubManager(POOL_A, address(h.oracleValuation), true);
        // Now that a feeder is wired up, switch the holding to the oracle valuation (still worth 0, since
        // nothing has been deposited yet) so subsequent price feeds drive its value.
        h.hub.updateHoldingValuation(POOL_A, SC_1, s_.usdcId, h.oracleValuation);
        vm.stopPrank();
    }

    function _configureBasePoolWithCustomAdapters(CSpoke memory s_) internal {
        // Wire pool adapters
        poolAdapterHToS = new LocalAdapter(h.centrifugeId, h.multiAdapter, FM);
        poolAdapterSToH = new LocalAdapter(s_.centrifugeId, s_.multiAdapter, FM);

        poolAdapterHToS.setEndpoint(poolAdapterSToH);
        poolAdapterSToH.setEndpoint(poolAdapterHToS);

        IAdapter[] memory localAdapters = new IAdapter[](1);
        localAdapters[0] = poolAdapterHToS;

        bytes32[] memory remoteAdapters = new bytes32[](1);
        remoteAdapters[0] = address(poolAdapterSToH).toBytes32();

        vm.startPrank(FM);
        h.hub.setAdapters{value: GAS}(POOL_A, s_.centrifugeId, localAdapters, remoteAdapters, 1, REFUND);
        h.hub.updateManager{value: GAS}(
            POOL_A, h.centrifugeId, ManagerKind.Adapter, GATEWAY_MANAGER.toBytes32(), true, REFUND
        );
        h.hub.updateManager{value: GAS}(
            POOL_A, s_.centrifugeId, ManagerKind.Adapter, GATEWAY_MANAGER.toBytes32(), true, REFUND
        );
    }

    function _configurePool(bool sameChain) internal {
        _setSpoke(sameChain);
        _createPool();
        _configurePoolInSpoke(s);
    }

    //----------------------------------------------------------------------------------------------
    // Price Management
    //----------------------------------------------------------------------------------------------

    function _configurePrices(D18 assetPrice, D18 sharePrice) internal {
        vm.startPrank(FEEDER);
        h.oracleValuation.setPrice(POOL_A, SC_1, s.usdcId, assetPrice);
        vm.stopPrank();

        vm.startPrank(FM);
        h.hub.updateSharePrice(POOL_A, SC_1, sharePrice, uint64(block.timestamp));
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, s.centrifugeId, REFUND);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, s.usdcId, REFUND);

        currentAssetPrice = assetPrice;
        currentSharePrice = sharePrice;

        vm.stopPrank();
    }

    function _configurePricesForFlow(bool nonZeroPrices) internal {
        _configurePrices(
            nonZeroPrices ? IntegrationConstants.assetPrice() : IntegrationConstants.zeroPrice(),
            nonZeroPrices ? IntegrationConstants.sharePrice() : IntegrationConstants.zeroPrice()
        );
    }

    //----------------------------------------------------------------------------------------------
    // Vault flows
    //----------------------------------------------------------------------------------------------

    /// @dev Canonical async plugins: per-request buckets, each folded as it settles, prices read from the
    ///      hub-notified spoke prices.
    function _defaultPlugins() internal view returns (VaultPlugins memory) {
        return VaultPlugins({
            oracle: IVaultOracle(address(s.spokeOracle)),
            instantPolicy: IInstantPolicy(address(0)),
            requestPolicy: s.perRequestPolicy,
            liquidityRoute: ILiquidityRoute(address(0)),
            settlementObserver: ISettlementObserver(address(0))
        });
    }

    function _deployVault() internal returns (IAsyncVault) {
        return _deployVaultWith(_defaultPlugins());
    }

    /// @dev Deploys a vault on the spoke, links it through the wire (`UpdateVault.DeployAndLink` with the
    ///      plugins and variant as the factory payload) and registers it as a spoke manager so it can
    ///      operate the escrow.
    function _deployVaultWith(VaultPlugins memory plugins) internal returns (IAsyncVault vault) {
        bytes memory payload = abi.encode(plugins, uint64(0), uint256(0));
        vault = IAsyncVault(payable(s.vaultFactory.deploy(POOL_A, SC_1, address(s.usdc), 0, payload)));

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A,
            SC_1,
            s.usdcId,
            address(s.vaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            payload,
            EXTRA_GAS,
            REFUND
        );
        assertTrue(s.spokeRegistry.isLinked(address(vault)), "vault not linked");
        h.hub.updateManager{value: GAS}(
            POOL_A, s.centrifugeId, ManagerKind.Spoke, address(vault).toBytes32(), true, REFUND
        );
        vm.stopPrank();
    }

    /// @dev Investor requests a deposit; the hub's OrderBook auto-approves it into the outstanding order.
    function _requestDeposit(IAsyncVault vault, uint128 amount) internal returns (RequestId requestId) {
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), amount);
        requestId = RequestId.wrap(vault.requestDeposit(amount, INVESTOR_A, INVESTOR_A));
        vm.stopPrank();

        assertEq(h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, requestId), amount, "order not registered");
    }

    /// @dev FM fulfils through the FeeRequestManager: policy-bounded managerCall into the OrderBook,
    ///      which sends one atomic settlement callback back to the vault.
    function _fulfill(bool isDeposit, RequestId requestId, uint128 fillAmount) internal {
        vm.startPrank(FM);
        h.feeRequestManager.fulfill{value: GAS}(
            POOL_A, SC_1, s.usdcId, requestId, isDeposit, fillAmount, EXTRA_GAS, REFUND
        );
        vm.stopPrank();
    }

    function _cancel(bool isDeposit, RequestId requestId, uint128 amount) internal {
        vm.startPrank(FM);
        h.feeRequestManager.cancel{value: GAS}(POOL_A, SC_1, s.usdcId, requestId, isDeposit, amount, EXTRA_GAS, REFUND);
        vm.stopPrank();
    }

    /// @dev Full async deposit: request -> auto-approve -> fulfil (approve/issue/fulfil callbacks) -> claim.
    function _testAsyncDeposit(bool sameChain) internal returns (IAsyncVault vault) {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        vault = _deployVault();

        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1);

        _fulfill(true, requestId, USDC_AMOUNT_1);

        uint128 shares = assetToShare(USDC_AMOUNT_1);
        assertEq(h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, requestId), 0, "order not consumed");
        assertEq(vault.maxDeposit(INVESTOR_A), USDC_AMOUNT_1, "claim not opened");
        assertEq(vault.maxMint(INVESTOR_A), shares);

        vm.prank(INVESTOR_A);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A);

        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares, "shares not claimed");
        assertEq(vault.maxDeposit(INVESTOR_A), 0);
    }

    /// @dev The same vault with the instant lane switched on. Everything else about it is unchanged,
    ///      so a difference between this and `_deployVault` is the instant policy and nothing else.
    function _deployInstantVault() internal returns (IAsyncVault) {
        VaultPlugins memory plugins = _defaultPlugins();
        plugins.instantPolicy = IInstantPolicy(address(s.reserveInstantPolicy));
        return _deployVaultWith(plugins);
    }

    /// @dev Opens the instant lane through the Envoy, the way a pool manager does: the reserve target
    ///      caps instant deposits, `redeemEnabled` opens the way out, and the two fee legs are basis
    ///      points on each side.
    function _configureInstantLane(uint128 maxReserve, uint16 depositFeeBps, uint16 redeemFeeBps, address feeRecipient)
        internal
    {
        bytes memory payload = _instantPayload(maxReserve, depositFeeBps, redeemFeeBps, feeRecipient);

        vm.startPrank(FM);
        h.hub.managerCall{value: sameChainCall() ? 0 : GAS}(
            POOL_A, s.centrifugeId, address(s.reserveInstantPolicy).toBytes32(), payload, EXTRA_GAS, 0, REFUND
        );
        vm.stopPrank();
    }

    /// @dev Split out to keep `_configureInstantLane` inside the stack limit.
    function _instantPayload(uint128 maxReserve, uint16 depositFeeBps, uint16 redeemFeeBps, address feeRecipient)
        internal
        view
        returns (bytes memory)
    {
        return abi.encode(
            IReserveInstantPolicy.ConfigKind.Terms,
            lastInstantVault,
            abi.encode(feeRecipient, depositFeeBps, redeemFeeBps, true, false, false, maxReserve)
        );
    }

    address internal lastInstantVault;

    function sameChainCall() internal view returns (bool) {
        return s.centrifugeId == h.centrifugeId;
    }
}

/// Common and generic flows ready to be used in different tests
contract EndToEndUseCases is EndToEndFlows {
    using CastLib for *;
    using MathLib for *;
    using MessageLib for *;

    /// @dev A configuration update reaches a spoke target (the QueueManager) via the `managerCall`
    ///      transport, addressing the target directly. Fuzzing `sameChain` covers both the local (direct
    ///      `fromHub`) and cross-chain (serialized message) branches. The hub lives on CENTRIFUGE_ID_A, so
    ///      the call is local iff `sameChain`: the `value` arg must equal `msg.value` locally and be 0
    ///      remotely, while `{value: GAS}` still funds the cross-chain message.
    /// forge-config: default.isolate = true
    function testManagerCallReachesSpokeTarget(bool sameChain) public {
        _configurePool(sameChain);

        uint64 newMinDelay = 123;
        (uint64 minDelay,,) = s.queueManager.scQueueState(POOL_A, SC_1);
        assertEq(minDelay, 0, "minDelay starts unset");

        vm.startPrank(FM);
        h.hub.managerCall{value: sameChain ? 0 : GAS}(
            POOL_A,
            s.centrifugeId,
            address(s.queueManager).toBytes32(),
            abi.encode(SC_1.raw(), newMinDelay, uint64(0)),
            EXTRA_GAS,
            0,
            REFUND
        );
        vm.stopPrank();

        (minDelay,,) = s.queueManager.scQueueState(POOL_A, SC_1);
        assertEq(minDelay, newMinDelay, "spoke target state updated via direct managerCall");
    }

    /// forge-config: default.isolate = true
    function testWardUpgrade(bool sameChain) public {
        address NEW_WARD = makeAddr("NewWard");

        _setSpoke(sameChain);

        vm.startPrank(address(SAFE_ADMIN_A));
        h.protocolGuardian.scheduleUpgrade{value: GAS}(s.centrifugeId, NEW_WARD, REFUND);
        h.protocolGuardian.cancelUpgrade{value: GAS}(s.centrifugeId, NEW_WARD, REFUND);
        h.protocolGuardian.scheduleUpgrade{value: GAS}(s.centrifugeId, NEW_WARD, REFUND);

        vm.startPrank(ANY);
        s.root.executeScheduledRely(NEW_WARD);
    }

    /// forge-config: default.isolate = true
    function testConfigureAsset(bool sameChain) public {
        _setSpoke(sameChain);
        _configureAsset(s);

        assertEq(h.hubRegistry.decimals(s.usdcId), 6, "expected decimals");
    }

    /// forge-config: default.isolate = true
    function testConfigurePool(bool sameChain) public {
        _configurePool(sameChain);
    }

    /// forge-config: default.isolate = true
    function testConfigurePoolExtra(bool sameChain) public {
        _configurePool(sameChain);

        vm.startPrank(FM);

        h.hub.updateShareClassMetadata(POOL_A, SC_1, "Tokenized MMF 2", "MMF2");
        h.hub.notifyShareMetadata{value: GAS}(POOL_A, SC_1, s.centrifugeId, 0, REFUND);
        _setHook(s, address(s.fullRestrictionsHook));

        assertEq(IShareToken(address(s.spokeRegistry.shareToken(POOL_A, SC_1))).name(), "Tokenized MMF 2");
        assertEq(IShareToken(address(s.spokeRegistry.shareToken(POOL_A, SC_1))).symbol(), "MMF2");
        assertEq(IShareToken(address(s.spokeRegistry.shareToken(POOL_A, SC_1))).hook(), address(s.fullRestrictionsHook));
    }

    /// @dev Hub-driven share issuance and revocation: Hub.updateManager grants ShareManager the spoke
    ///      manager bit, then Hub.managerCall -> Envoy -> ShareManager.fromHub -> Spoke.issue/revoke.
    /// forge-config: default.isolate = true
    function testShareManager(bool sameChain) public {
        uint128 shares = 100e18;
        _configurePool(sameChain);

        vm.startPrank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );
        h.hub.updateManager{value: GAS}(
            POOL_A, s.centrifugeId, ManagerKind.Spoke, address(s.shareManager).toBytes32(), true, REFUND
        );

        h.hub.managerCall{value: sameChain ? 0 : GAS}(
            POOL_A,
            s.centrifugeId,
            address(s.shareManager).toBytes32(),
            abi.encode(uint8(IShareManager.ManagerCall.Issue), SC_1.raw(), INVESTOR_A.toBytes32(), shares),
            EXTRA_GAS,
            0,
            REFUND
        );

        IShareToken share = IShareToken(address(s.spokeRegistry.shareToken(POOL_A, SC_1)));
        assertEq(share.balanceOf(INVESTOR_A), shares, "shares issued to investor");
        assertEq(share.totalSupply(), shares, "total supply increased");

        h.hub.managerCall{value: sameChain ? 0 : GAS}(
            POOL_A,
            s.centrifugeId,
            address(s.shareManager).toBytes32(),
            abi.encode(uint8(IShareManager.ManagerCall.Revoke), SC_1.raw(), INVESTOR_A.toBytes32(), shares),
            SHARE_REVOKE_EXTRA_GAS,
            0,
            REFUND
        );

        assertEq(share.balanceOf(INVESTOR_A), 0, "shares revoked from investor");
        assertEq(share.totalSupply(), 0, "total supply decreased");
    }

    /// @dev Hub pushes a spoke pool's policy end-to-end: Hub.setSpokePolicy -> SetPolicy
    ///      message -> SpokeHandler.setPolicy -> SpokeRegistry.policy.
    /// forge-config: default.isolate = true
    function testSetSpokePolicy(bool sameChain) public {
        _configurePool(sameChain);

        address policy = makeAddr("spokePolicy");

        vm.prank(FM);
        h.hub.setSpokePolicy{value: GAS}(POOL_A, s.centrifugeId, policy.toBytes32(), REFUND);

        assertEq(address(s.spokeRegistry.policy(POOL_A)), policy);
    }

    /// @dev Hub authorizes an out-of-policy spoke call end-to-end: Hub.authorizeSpokeCall -> Authorize
    ///      message -> SpokeHandler.authorize -> SpokeRegistry records it, consumed later by the policy.
    /// forge-config: default.isolate = true
    function testAuthorizeSpokeCall(bool sameChain) public {
        _configurePool(sameChain);

        address policy = makeAddr("spokePolicy");
        vm.prank(FM);
        h.hub.setSpokePolicy{value: GAS}(POOL_A, s.centrifugeId, policy.toBytes32(), REFUND);

        bytes memory data = hex"1234"; // arbitrary; matched by exact bytes

        vm.prank(FM);
        h.hub.authorizeSpokeCall{value: GAS}(POOL_A, s.centrifugeId, data, REFUND);

        bytes32 id = s.spokeRegistry.authId(POOL_A, data);
        assertEq(s.spokeRegistry.authorizations(id), 1);

        // Policy consumes the authorization directly.
        vm.prank(policy);
        s.spokeRegistry.consumeAuthorization(POOL_A, FM, data);
        assertEq(s.spokeRegistry.authorizations(id), 0);
    }

    /// @dev Hub revokes an outstanding spoke authorization end-to-end: Hub.unauthorizeSpokeCall -> Unauthorize
    ///      message -> SpokeHandler.unauthorize -> SpokeRegistry decrements the counter.
    /// forge-config: default.isolate = true
    function testUnauthorizeSpokeCall(bool sameChain) public {
        _configurePool(sameChain);

        address policy = makeAddr("spokePolicy");
        vm.prank(FM);
        h.hub.setSpokePolicy{value: GAS}(POOL_A, s.centrifugeId, policy.toBytes32(), REFUND);

        bytes memory data = hex"1234"; // arbitrary; matched by exact bytes

        vm.prank(FM);
        h.hub.authorizeSpokeCall{value: GAS}(POOL_A, s.centrifugeId, data, REFUND);

        bytes32 id = s.spokeRegistry.authId(POOL_A, data);
        assertEq(s.spokeRegistry.authorizations(id), 1);

        // Hub retires the outstanding authorization, decrementing the counter.
        vm.prank(FM);
        h.hub.unauthorizeSpokeCall{value: GAS}(POOL_A, s.centrifugeId, data, REFUND);
        assertEq(s.spokeRegistry.authorizations(id), 0);
    }

    /// @dev Routes a guarded spoke call through {Spoke.enforced} into a real policy's {enforce}: blocked
    ///      until the Hub authorizes it, with the policy seeing the Spoke as caller and the acting manager
    ///      as `caller`. Covers the wiring the authorize/unauthorize tests skip (they consume directly).
    /// forge-config: default.isolate = true
    function testEnforceSpokeCall(bool sameChain) public {
        _configurePool(sameChain);

        // Guard `deposit`: out of policy, so it must be pre-authorized via the Hub before it can run.
        MockSpokePolicy policy = new MockSpokePolicy(s.spokeRegistry, address(s.spoke), Spoke.deposit.selector);
        vm.prank(FM);
        h.hub.setSpokePolicy{value: GAS}(POOL_A, s.centrifugeId, address(policy).toBytes32(), REFUND);

        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, USDC_AMOUNT_1);
        vm.prank(BSM);
        s.usdc.approve(address(s.spoke), USDC_AMOUNT_1);

        bytes memory data = abi.encodeCall(Spoke.deposit, (POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1));

        // Not yet authorized: Spoke.enforced -> policy.enforce -> consumeAuthorization reverts.
        vm.prank(BSM);
        vm.expectRevert(ISpokeRegistry.NoOutstandingAuthorization.selector);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);

        // Hub authorizes the exact spoke calldata.
        vm.prank(FM);
        h.hub.authorizeSpokeCall{value: GAS}(POOL_A, s.centrifugeId, data, REFUND);
        bytes32 id = s.spokeRegistry.authId(POOL_A, data);
        assertEq(s.spokeRegistry.authorizations(id), 1);

        // Same call now succeeds: enforce consumes the authorization.
        vm.prank(BSM);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);

        // The policy was invoked by the Spoke (its `msg.sender == enforcer` gate held) with BSM as caller.
        assertEq(policy.lastCaller(), BSM);
        assertEq(policy.enforceCalls(), 1); // the reverted attempt rolled back its increment
        assertEq(s.spokeRegistry.authorizations(id), 0); // consumed
        assertEq(s.spoke.availableBalanceOf(POOL_A, SC_1, address(s.usdc), 0), USDC_AMOUNT_1);
    }

    /// forge-config: default.isolate = true
    function testFundManagement(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, USDC_AMOUNT_1);

        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), USDC_AMOUNT_1);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);
        s.spoke.withdraw(POOL_A, SC_1, address(s.usdc), 0, BSM, USDC_AMOUNT_1 * 4 / 5);
        s.spoke.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, EXTRA_GAS, REFUND);

        // CHECKS
        assertEq(s.usdc.balanceOf(BSM), USDC_AMOUNT_1 * 4 / 5);
        assertEq(s.spoke.availableBalanceOf(POOL_A, SC_1, address(s.usdc), 0), USDC_AMOUNT_1 / 5);

        (uint128 amount, uint128 value,) = h.holdings.holding(POOL_A, SC_1, s.usdcId);
        assertEq(amount, USDC_AMOUNT_1 / 5);
        assertEq(value, assetToPool(USDC_AMOUNT_1 / 5));

        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), 1);

        checkAccountValue(ASSET_ACCOUNT, assetToPool(USDC_AMOUNT_1 / 5), true);
        checkAccountValue(EQUITY_ACCOUNT, assetToPool(USDC_AMOUNT_1 / 5), true);
    }

    /// @dev UpdateRestriction's three sub-messages share one GasService budget, and the benchmarker keeps
    ///      the max per message type, so each has to cross the gateway once for the budget to cover it. The
    ///      investment flows send Member; this sends the other two. Not fuzzed and not same-chain: one
    ///      cross-chain pass is all the benchmark reads.
    /// forge-config: default.isolate = true
    function testUpdateRestrictionFreezeAndUnfreeze() public {
        _configurePool(IN_DIFFERENT_CHAINS);

        vm.startPrank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        // Freeze an address that has never held shares or been a member. Its hook data is written from
        // zero, which is the expensive Freeze and the one the shared budget has to cover; freezing the investor
        // just made a member would land on an already-nonzero slot and stay cheaper than Member.
        address blocked = makeAddr("blocked");
        IShareToken shareToken = IShareToken(address(s.spokeRegistry.shareToken(POOL_A, SC_1)));

        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionFreezeMsg(blocked), EXTRA_GAS, REFUND
        );
        assertTrue(s.redemptionRestrictionsHook.isFrozen(address(shareToken), blocked), "frozen");

        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionUnfreezeMsg(blocked), EXTRA_GAS, REFUND
        );
        assertFalse(s.redemptionRestrictionsHook.isFrozen(address(shareToken), blocked), "unfrozen");
    }

    /// forge-config: default.isolate = true
    function testAdaptersPerPool() public {
        _setSpoke(IN_DIFFERENT_CHAINS);
        _createPool();
        _configureBasePoolWithCustomAdapters(s);

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, s.centrifugeId, REFUND);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);

        // Hub -> Spoke message went through the pool adapter
        assertEq(uint8(poolAdapterHToS.lastReceivedPayload().messageType()), uint8(MessageType.NotifyPool));
        assertEq(s.spokeRegistry.pool(POOL_A), block.timestamp); // Message received and processed

        h.hub.updateManager{value: GAS}(POOL_A, s.centrifugeId, ManagerKind.Spoke, BSM.toBytes32(), true, REFUND);

        vm.startPrank(BSM);
        s.spoke.submitQueuedShares{value: GAS}(POOL_A, SC_1, EXTRA_GAS, REFUND);

        // Spoke -> Hub message went through the pool adapter
        assertEq(uint8(poolAdapterSToH.lastReceivedPayload().messageType()), uint8(MessageType.UpdateShares));

        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), 1); // Message received and processed
    }

    /// forge-config: default.isolate = true
    function testMaxAdaptersConfigurationBenchmark() public {
        // This tests is just to compute the SetPoolAdapters max weight used in GasService

        _setSpoke(IN_DIFFERENT_CHAINS);
        _createPool();

        IAdapter[] memory localAdapters = new IAdapter[](1);
        localAdapters[0] = new LocalAdapter(h.centrifugeId, h.multiAdapter, FM);

        bytes32[] memory remoteAdapters = new bytes32[](MAX_ADAPTER_COUNT);
        for (uint256 i; i < MAX_ADAPTER_COUNT; i++) {
            IAdapter adapter = new LocalAdapter(s.centrifugeId, s.multiAdapter, FM);
            remoteAdapters[i] = address(adapter).toBytes32();
        }

        vm.startPrank(FM);
        h.hub.setAdapters{value: GAS}(POOL_A, s.centrifugeId, localAdapters, remoteAdapters, 1, REFUND);
    }

    /// forge-config: default.isolate = true
    function testErrSetAdaptersLocally() public {
        _setSpoke(IN_DIFFERENT_CHAINS);
        _createPool();

        IAdapter[] memory localAdapters = new IAdapter[](1);
        localAdapters[0] = new LocalAdapter(h.centrifugeId, h.multiAdapter, FM);

        bytes32[] memory remoteAdapters = new bytes32[](MAX_ADAPTER_COUNT);
        for (uint256 i; i < MAX_ADAPTER_COUNT; i++) {
            IAdapter adapter = new LocalAdapter(s.centrifugeId, s.multiAdapter, FM);
            remoteAdapters[i] = address(adapter).toBytes32();
        }

        vm.expectRevert(ILocalCentrifugeId.CannotBeSentLocally.selector);
        vm.startPrank(FM);
        h.hub.setAdapters{value: GAS}(POOL_A, h.centrifugeId, localAdapters, remoteAdapters, 1, REFUND);
    }

    function testErrSetAdaptersWhileBatching() public {
        _setSpoke(IN_DIFFERENT_CHAINS);
        _createPool();

        IAdapter[] memory localAdapters = new IAdapter[](1);
        localAdapters[0] = new LocalAdapter(h.centrifugeId, h.multiAdapter, FM);

        bytes32[] memory remoteAdapters = new bytes32[](1);
        remoteAdapters[0] = address(new LocalAdapter(s.centrifugeId, s.multiAdapter, FM)).toBytes32();

        // Batching defers the SetPoolAdapters send until after the new local set is applied, which would
        // route it over a set the spoke does not yet trust, so setAdapters must reject being batched.
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeWithSelector(
            h.hub.setAdapters.selector,
            POOL_A,
            s.centrifugeId,
            localAdapters,
            remoteAdapters,
            uint8(1),
            uint8(1),
            REFUND
        );

        vm.expectRevert(IHub.CannotSetAdaptersWhileBatching.selector);
        vm.prank(FM);
        h.hub.multicall{value: GAS}(calls);
    }

    /// forge-config: default.isolate = true
    function testWithdrawSubsidyFromVaults(bool sameChain) public {
        _configurePool(sameChain);

        address RECEIVER = makeAddr("Receiver");
        uint256 VALUE = 123;

        vm.startPrank(FM);
        h.hub.managerCall{value: sameChain ? 0 : GAS}(
            POOL_A,
            s.centrifugeId,
            address(s.subsidyManager).toBytes32(),
            abi.encode(RECEIVER.toBytes32(), VALUE),
            EXTRA_GAS,
            0,
            REFUND
        );

        assertEq(RECEIVER.balance, VALUE);
    }

    //----------------------------------------------------------------------------------------------
    // Vault use cases
    //----------------------------------------------------------------------------------------------

    /// forge-config: default.isolate = true
    function testAsyncDeposit(bool sameChain) public {
        _testAsyncDeposit(sameChain);
    }

    /// forge-config: default.isolate = true
    function testAsyncRedeem(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        uint128 shares = assetToShare(USDC_AMOUNT_1);

        // Redemptions are restricted: the investor must be a member before requesting.
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A));
        assertEq(h.orderBook.redeemOrders(POOL_A, SC_1, s.usdcId, requestId), shares, "redeem order not registered");

        _fulfill(false, requestId, shares);

        assertEq(vault.maxWithdraw(INVESTOR_A), shareToAsset(shares), "payout not claimable");

        vm.prank(INVESTOR_A);
        vault.redeem(shares, INVESTOR_A);

        assertEq(s.usdc.balanceOf(INVESTOR_A), shareToAsset(shares), "assets not paid out");
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), 0);
    }

    /// @dev Cancellation is order-level: the manager retires part of the outstanding order and the
    ///      cancelled assets become claimable through the redeem side.
    /// forge-config: default.isolate = true
    function testAsyncDepositCancel(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        IAsyncVault vault = _deployVault();

        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);
        _cancel(true, requestId, USDC_AMOUNT_1);

        assertEq(h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, requestId), 0, "order not retired");
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), 0, "pending not cleared");
        assertEq(vault.maxWithdraw(INVESTOR_A), USDC_AMOUNT_1, "cancelled assets not claimable");

        vm.prank(INVESTOR_A);
        vault.withdraw(USDC_AMOUNT_1, INVESTOR_A);

        assertEq(s.usdc.balanceOf(INVESTOR_A), USDC_AMOUNT_1, "cancelled assets not returned");
    }

    /// @dev A partial fill folds without completing the position, so the callback writes the fold snapshot
    ///      where a full fill deletes it; the benchmark needs both.
    /// forge-config: default.isolate = true
    function testAsyncDepositPartialFillThenCancel(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        IAsyncVault vault = _deployVault();

        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);
        uint128 half = USDC_AMOUNT_1 / 2;
        _fulfill(true, requestId, half);

        assertEq(vault.maxDeposit(INVESTOR_A), half, "half claimable");
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1 - half, "half pending");

        _cancel(true, requestId, USDC_AMOUNT_1 - half);

        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), 0, "pending cleared");
        assertEq(vault.maxWithdraw(INVESTOR_A), USDC_AMOUNT_1 - half, "rest refunded");
    }

    /// @dev Unlink detaches the vault from new requests; relinking reattaches it. Covers the Link and
    ///      Unlink wire kinds (DeployAndLink is covered by every vault flow).
    /// forge-config: default.isolate = true
    function testVaultLinkUnlink(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        IAsyncVault vault = _deployVault();

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, address(vault).toBytes32(), VaultUpdateKind.Unlink, bytes(""), EXTRA_GAS, REFUND
        );
        assertFalse(s.spokeRegistry.isLinked(address(vault)), "vault still linked");

        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, address(vault).toBytes32(), VaultUpdateKind.Link, bytes(""), EXTRA_GAS, REFUND
        );
        assertTrue(s.spokeRegistry.isLinked(address(vault)), "vault not relinked");
        vm.stopPrank();

        _requestDeposit(vault, USDC_AMOUNT_1);
    }

    /// @dev Retiring a vault, against the real Spoke and not a mock of it: a settled position is still claimed after
    ///      `Unlink`, because every claim pays through the Spoke as a call by the vault, which only needs the vault to
    ///      still be a manager. Revoking the role first freezes the claim with `NotManager`, and granting it back
    ///      releases it, so the role stays until the claims are paid.
    /// forge-config: default.isolate = true
    function testAnUnlinkedVaultPaysItsClaimsOnlyWhileItIsStillAManager(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        IAsyncVault vault = _deployVault();
        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);
        _fulfill(true, requestId, USDC_AMOUNT_1);
        uint128 shares = assetToShare(USDC_AMOUNT_1);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, address(vault).toBytes32(), VaultUpdateKind.Unlink, bytes(""), EXTRA_GAS, REFUND
        );
        h.hub.updateManager{value: GAS}(
            POOL_A, s.centrifugeId, ManagerKind.Spoke, address(vault).toBytes32(), false, REFUND
        );
        vm.stopPrank();
        assertFalse(s.spokeRegistry.isLinked(address(vault)), "still linked");
        assertEq(vault.maxMint(INVESTOR_A), shares, "the claim is still on the ledger");

        vm.prank(INVESTOR_A);
        vm.expectRevert(ISpoke.NotManager.selector);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);

        vm.prank(FM);
        h.hub.updateManager{value: GAS}(
            POOL_A, s.centrifugeId, ManagerKind.Spoke, address(vault).toBytes32(), true, REFUND
        );
        vm.prank(INVESTOR_A);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares, "the claim paid once the role was back");
    }

    /// @dev The same retirement with the role kept: `Unlink` alone leaves every claim payable.
    /// forge-config: default.isolate = true
    function testAnUnlinkedVaultThatKeepsItsRolePaysItsClaims(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        IAsyncVault vault = _deployVault();
        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);
        _fulfill(true, requestId, USDC_AMOUNT_1);

        vm.prank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, address(vault).toBytes32(), VaultUpdateKind.Unlink, bytes(""), EXTRA_GAS, REFUND
        );

        vm.prank(INVESTOR_A);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "paid unlinked");
    }

    /// @dev A fulfil forwards its value into the OrderBook's own batch: the batch cost is paid once and
    ///      the remainder is refunded, so no value strands in the hub, envoy, order book, or manager.
    /// forge-config: default.isolate = true
    function testFulfillLeavesNoStrandedValue(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);

        assertEq(address(h.hub).balance, 0, "value stranded in hub");
        assertEq(address(h.orderBook).balance, 0, "value stranded in order book");
        assertEq(address(h.feeRequestManager).balance, 0, "value stranded in fee manager");
        assertEq(address(vault).balance, 0, "value stranded in vault");
    }

    /// @dev The same vault on `PerInvestorPolicy`, which is the default request model and had never
    ///      run end to end: one bucket per controller per side, reused across requests.
    function _deployPerInvestorVault() internal returns (IAsyncVault) {
        VaultPlugins memory plugins = _defaultPlugins();
        plugins.requestPolicy = s.perInvestorPolicy;
        return _deployVaultWith(plugins);
    }

    //----------------------------------------------------------------------------------------------
    // Instant (ERC-4626) lane
    //----------------------------------------------------------------------------------------------

    /// @dev The ERC-4626 lane against the real escrow. Every other test of it mocks the spoke, so
    ///      nothing has ever checked that an instant deposit's assets reach the escrow, that the
    ///      shares are minted against them, or that the fee leaves for its recipient — the three
    ///      things that move money.
    /// forge-config: default.isolate = true
    function testInstantDeposit(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployInstantVault();
        lastInstantVault = address(vault);
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 0, address(0));

        assertEq(vault.maxDeposit(INVESTOR_A), USDC_AMOUNT_1 * 10, "the reserve headroom is the capacity");

        address escrow = vault.escrow();
        uint256 escrowBefore = s.usdc.balanceOf(escrow);

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        uint256 shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        vm.stopPrank();

        assertEq(shares, assetToShare(USDC_AMOUNT_1), "priced at the notified prices");
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares, "shares issued to the investor");
        assertEq(s.usdc.balanceOf(escrow) - escrowBefore, USDC_AMOUNT_1, "the assets reached the escrow");
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), 0, "an instant deposit is not a request");
    }

    /// @dev The entry fee leaves the flow entirely: the escrow receives the deposit less the fee, the
    ///      recipient receives the fee, and the shares are priced on what actually backs them.
    /// forge-config: default.isolate = true
    function testInstantDepositChargesTheEntryFee(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployInstantVault();
        lastInstantVault = address(vault);

        address feeRecipient = makeAddr("feeRecipient");
        // 1% on the way in.
        _configureInstantLane(USDC_AMOUNT_1 * 10, 100, 0, feeRecipient);

        address escrow = vault.escrow();
        uint256 escrowBefore = s.usdc.balanceOf(escrow);
        uint128 fee = USDC_AMOUNT_1 / 100;

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        uint256 shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        vm.stopPrank();

        assertEq(s.usdc.balanceOf(feeRecipient), fee, "the fee left for its recipient");
        assertEq(s.usdc.balanceOf(escrow) - escrowBefore, USDC_AMOUNT_1 - fee, "the escrow got the rest");
        assertEq(shares, assetToShare(USDC_AMOUNT_1 - fee), "and the shares are priced on what backs them");
    }

    /// @dev The way back out, against the escrow the deposit filled. The shares are burnt and the
    ///      assets leave the escrow for the investor, both through the real spoke accounting.
    /// forge-config: default.isolate = true
    function testInstantRedeem(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployInstantVault();
        lastInstantVault = address(vault);
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 0, address(0));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        uint256 shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        vm.stopPrank();

        // An instant exit is a redeem request and its claim at once, so under RedemptionRestrictions
        // it is closed to a holder who is not a member, as `requestRedeem` would be.
        assertEq(vault.maxRedeem(INVESTOR_A), 0, "a non-member has no way out");
        vm.prank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.redeem(shares, INVESTOR_A);

        _addMember(INVESTOR_A);

        address escrow = vault.escrow();
        uint256 escrowBefore = s.usdc.balanceOf(escrow);
        uint256 investorBefore = s.usdc.balanceOf(INVESTOR_A);

        assertGt(vault.maxRedeem(INVESTOR_A), 0, "the way out is open");

        vm.prank(INVESTOR_A);
        uint256 assets = vault.redeem(shares, INVESTOR_A);

        assertEq(assets, USDC_AMOUNT_1, "a round trip at an unchanged price returns the deposit");
        assertEq(s.usdc.balanceOf(INVESTOR_A) - investorBefore, assets, "the investor was paid");
        assertEq(escrowBefore - s.usdc.balanceOf(escrow), assets, "out of the escrow");
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), 0, "and the shares were burnt");
    }

    /// @dev The exit fee stays behind: the investor receives the payout net of it and the recipient is
    ///      paid out of the escrow, so the two legs together are what leaves.
    /// forge-config: default.isolate = true
    function testInstantRedeemChargesTheExitFee(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployInstantVault();
        lastInstantVault = address(vault);

        address feeRecipient = makeAddr("feeRecipient");
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 100, feeRecipient);

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        uint256 shares = vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        vm.stopPrank();

        _addMember(INVESTOR_A);
        uint256 investorBefore = s.usdc.balanceOf(INVESTOR_A);
        uint128 fee = USDC_AMOUNT_1 / 100;

        vm.prank(INVESTOR_A);
        uint256 assets = vault.redeem(shares, INVESTOR_A);

        assertEq(assets, USDC_AMOUNT_1 - fee, "the payout is net of the exit fee");
        assertEq(s.usdc.balanceOf(INVESTOR_A) - investorBefore, assets, "which is what the investor received");
        assertEq(s.usdc.balanceOf(feeRecipient), fee, "and the fee reached its recipient");
    }

    //----------------------------------------------------------------------------------------------
    // Request models
    //----------------------------------------------------------------------------------------------

    /// @dev `PerInvestorPolicy` is the request model a pool gets unless it asks for another, and every
    ///      end-to-end flow until now ran on `PerRequestPolicy`. The difference that matters here is
    ///      that its bucket is keyed by controller and side, so a second request lands in the same
    ///      bucket as the first and the position accumulates instead of forking.
    /// forge-config: default.isolate = true
    function testAsyncDepositOnThePerInvestorPolicy(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployPerInvestorVault();
        uint128 half = USDC_AMOUNT_1 / 2;

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        RequestId first = RequestId.wrap(vault.requestDeposit(half, INVESTOR_A, INVESTOR_A));
        RequestId second = RequestId.wrap(vault.requestDeposit(half, INVESTOR_A, INVESTOR_A));
        vm.stopPrank();

        assertEq(RequestId.unwrap(first), RequestId.unwrap(second), "both requests share one bucket");
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1, "and the position accumulated");
        assertEq(
            h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, first),
            USDC_AMOUNT_1,
            "the hub sees one order for the whole amount"
        );

        _fulfill(true, first, USDC_AMOUNT_1);

        uint128 shares = assetToShare(USDC_AMOUNT_1);
        assertEq(vault.maxMint(INVESTOR_A), shares, "the whole position is claimable at once");

        vm.prank(INVESTOR_A);
        vault.mint(shares, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares, "shares claimed");
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), 0);
    }

    /// @dev The bucket is derived from the controller rather than from a counter, so it is reused for
    ///      good. A settled position must therefore leave it usable again, which is the whole reason
    ///      the settlement library retires a sole owner's bucket.
    /// forge-config: default.isolate = true
    function testAPerInvestorBucketIsReusableAfterItSettles(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployPerInvestorVault();
        uint128 half = USDC_AMOUNT_1 / 2;

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        RequestId requestId = RequestId.wrap(vault.requestDeposit(half, INVESTOR_A, INVESTOR_A));
        vm.stopPrank();

        _fulfill(true, requestId, half);

        // Read before the prank: an argument is evaluated first, and would consume it.
        uint256 claimable = vault.maxMint(INVESTOR_A);
        assertGt(claimable, 0, "the first request settled");

        vm.prank(INVESTOR_A);
        vault.mint(claimable, INVESTOR_A);

        // The same id again, on a bucket that has been through a full settlement.
        vm.prank(INVESTOR_A);
        RequestId again = RequestId.wrap(vault.requestDeposit(half, INVESTOR_A, INVESTOR_A));

        assertEq(RequestId.unwrap(again), RequestId.unwrap(requestId), "the id is the controller's, for good");
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), half, "and it takes a new request");

        _fulfill(true, again, half);
        assertGt(vault.maxMint(INVESTOR_A), 0, "which settles like any other");
    }

    //----------------------------------------------------------------------------------------------
    // Batching, gating and cancellation
    //----------------------------------------------------------------------------------------------

    /// @dev `PerPeriodPolicy` is the only shipped model that puts more than one controller in a bucket,
    ///      and the only one that batches: a window's requests accumulate spoke-side and reach the hub
    ///      as a single order when the window closes. Nothing had run it end to end, so nothing had
    ///      checked that the deferred transport actually defers, or that the pro-rata distribution
    ///      arrives intact on the other side of the wire.
    /// forge-config: default.isolate = true
    function testABatchedWindowReachesTheHubAsOneOrder(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        PerPeriodPolicy perPeriod = new PerPeriodPolicy(1 days, 0, 0, 0);
        VaultPlugins memory plugins = _defaultPlugins();
        plugins.requestPolicy = perPeriod;

        IAsyncVault vault = _deployVaultWith(plugins);
        uint128 half = USDC_AMOUNT_1 / 2;

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        RequestId requestId = RequestId.wrap(vault.requestDeposit(half, INVESTOR_A, INVESTOR_A));
        vault.requestDeposit(half, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();

        assertEq(
            h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, requestId),
            0,
            "a batched window is held spoke-side, not sent"
        );
        assertEq(
            vault.bucket(uint96(RequestId.unwrap(requestId))).queued, USDC_AMOUNT_1, "it accumulates in the bucket"
        );
        assertEq(vault.pendingDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1, "and counts as pending throughout");

        // The window closes; anyone may push it, which is what makes the batch keeper-driven.
        vm.warp(block.timestamp + 1 days);
        vault.flushRequest(uint96(RequestId.unwrap(requestId)));

        assertEq(
            h.orderBook.depositOrders(POOL_A, SC_1, s.usdcId, requestId),
            USDC_AMOUNT_1,
            "the whole window arrived as one order"
        );

        _fulfill(true, requestId, USDC_AMOUNT_1);

        uint128 shares = assetToShare(USDC_AMOUNT_1);
        assertEq(vault.maxMint(INVESTOR_A), shares, "the fulfillment folded to the contributor");

        vm.prank(INVESTOR_A);
        vault.mint(shares, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares);
    }

    /// @dev Under `RedemptionRestrictions` a redeem request is a vault action the hook holds to members.
    ///      It has no transfer leg the token would see, so this is the vault asking the hook itself.
    /// forge-config: default.isolate = true
    function testANonMemberCannotRequestARedemption(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        uint256 shares = IShareToken(vault.share()).balanceOf(INVESTOR_A);

        vm.prank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);

        _addMember(INVESTOR_A);
        vm.prank(INVESTOR_A);
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);
        assertEq(vault.pendingRedeemRequest(0, INVESTOR_A), shares, "a member can");
    }

    /// @dev A deposit request is gated on the controller not being frozen, before any asset moves.
    /// forge-config: default.isolate = true
    function testAFrozenControllerCannotRequestADeposit(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
        IAsyncVault vault = _deployVault();

        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionFreezeMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();

        assertEq(s.usdc.balanceOf(INVESTOR_A), USDC_AMOUNT_1, "the assets never left");
    }

    /// @dev Taking on a redeem position means being able to redeem, so under `RedemptionRestrictions`
    ///      a redeem request can only be transferred to a member.
    /// forge-config: default.isolate = true
    function testARedeemRequestCannotBeTransferredToANonMember(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        uint256 shares = IShareToken(vault.share()).balanceOf(INVESTOR_A);
        _addMember(INVESTOR_A);

        VaultPlugins memory plugins = _defaultPlugins();
        plugins.requestPolicy = new PerPeriodPolicy(1 days, 0, 0, 0);
        IAsyncVault windowed = _deployVaultWith(plugins);

        address recipient = makeAddr("recipient");
        vm.prank(INVESTOR_A);
        uint256 requestId = windowed.requestRedeem(shares, INVESTOR_A, INVESTOR_A);

        vm.prank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        IERC8161RedeemTransferable(address(windowed)).transferRedeemRequest(requestId, INVESTOR_A, recipient);

        _addMember(recipient);
        vm.prank(INVESTOR_A);
        IERC8161RedeemTransferable(address(windowed)).transferRedeemRequest(requestId, INVESTOR_A, recipient);
        assertEq(windowed.pendingRedeemRequest(0, recipient), shares, "a member can take it on");
    }

    /// @dev The share class's restriction hook gates the claim on its escrow-to-receiver leg, an
    ///      enforced transfer, and `maxDeposit` reads the same check through the token, so a frozen
    ///      investor sees no capacity and cannot take delivery.
    /// forge-config: default.isolate = true
    function testTheShareHookGatesTheClaim(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployVaultWith(_defaultPlugins());

        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);
        _fulfill(true, requestId, USDC_AMOUNT_1);

        uint128 shares = assetToShare(USDC_AMOUNT_1);
        assertEq(vault.maxDeposit(INVESTOR_A), USDC_AMOUNT_1, "a member can take delivery");

        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionFreezeMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        assertEq(vault.claimableDepositRequest(0, INVESTOR_A), USDC_AMOUNT_1, "the fulfillment is still a fact");
        assertEq(vault.maxDeposit(INVESTOR_A), 0, "but a frozen investor cannot take delivery of it");

        // The claim is refused by the hook before any share moves
        vm.prank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A);

        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionUnfreezeMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        assertEq(vault.maxDeposit(INVESTOR_A), USDC_AMOUNT_1, "unfreezing reopens the claim");

        vm.prank(INVESTOR_A);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares, "and it goes through");
    }

    /// @dev The redeem-side cancellation, which had no end-to-end test. Cancelled redeem shares stay
    ///      parked in the escrow and are claimed through the *deposit* side, so an integrator
    ///      recovers them through `mint` without knowing cancellation exists.
    /// forge-config: default.isolate = true
    function testAsyncRedeemCancel(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        uint128 shares = assetToShare(USDC_AMOUNT_1);

        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND
        );

        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A));
        assertEq(vault.pendingRedeemRequest(0, INVESTOR_A), shares, "the shares are in flight");

        _cancel(false, requestId, shares);

        assertEq(h.orderBook.redeemOrders(POOL_A, SC_1, s.usdcId, requestId), 0, "the order was retired");
        assertEq(vault.pendingRedeemRequest(0, INVESTOR_A), 0, "and nothing is pending any more");
        assertEq(vault.maxMint(INVESTOR_A), shares, "the shares come back through the deposit side");

        vm.prank(INVESTOR_A);
        vault.mint(shares, INVESTOR_A);

        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares, "the investor has them back");
        assertEq(vault.maxMint(INVESTOR_A), 0);
    }

    /// @dev The two lanes share one address and one position, and the routing between them is the
    ///      specification's central deviation from ERC-4626. With an open request the 2-arg entrypoints must
    ///      claim rather than trade, however much instant capacity the policy is offering.
    /// forge-config: default.isolate = true
    function testAPendingRequestClosesTheInstantLaneForThatController(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        IAsyncVault vault = _deployInstantVault();
        lastInstantVault = address(vault);
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 0, address(0));

        assertGt(vault.maxDeposit(INVESTOR_A), 0, "the instant lane is open to start with");

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        RequestId requestId = RequestId.wrap(vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A));
        vm.stopPrank();

        assertEq(vault.maxDeposit(INVESTOR_A), 0, "an open request closes it for this controller");

        _fulfill(true, requestId, USDC_AMOUNT_1);
        uint128 claimable = assetToShare(USDC_AMOUNT_1);
        assertEq(vault.maxMint(INVESTOR_A), claimable, "and it reopens as a claim, not as capacity");

        vm.prank(INVESTOR_A);
        vault.mint(claimable, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), claimable, "the 2-arg mint claimed");

        assertGt(vault.maxDeposit(INVESTOR_A), 0, "with nothing in flight the instant lane is back");
    }

    /// forge-config: default.isolate = true
    function testManagerCallFromSpoke(bool sameChain) public {
        _configurePool(sameChain);

        address hubContract = address(new IsContract());
        address spokeSender = makeAddr("SpokeSender");

        vm.mockCall(
            hubContract,
            abi.encodeWithSelector(
                IManagerCallFromSpoke.fromSpoke.selector, POOL_A, "data", s.centrifugeId, spokeSender.toBytes32()
            ),
            abi.encode()
        );

        vm.startPrank(spokeSender);
        vm.deal(spokeSender, GAS);
        s.spoke.managerCall{value: GAS}(POOL_A, hubContract.toBytes32(), "data", EXTRA_GAS, REFUND);
    }
}
