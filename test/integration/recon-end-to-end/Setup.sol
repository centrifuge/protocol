// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20Basin} from "./mocks/ERC20Basin.sol";
import {CountingObserver} from "./mocks/CountingObserver.sol";
import {EvilVaultFactory} from "./mocks/EvilVaultFactory.sol";
import {HostileUnderlying} from "./mocks/HostileUnderlying.sol";
import {RevertingObserver} from "./mocks/RevertingObserver.sol";
import {RebatingInstantPolicy} from "./mocks/RebatingInstantPolicy.sol";

import {ERC20} from "../../../src/misc/ERC20.sol";
import {D18, d18} from "../../../src/misc/types/D18.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";

import {Hub} from "../../../src/core/hub/Hub.sol";
import {Envoy} from "../../../src/core/utils/Envoy.sol";
import {Spoke} from "../../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../../src/core/types/PoolId.sol";
import {Holdings} from "../../../src/core/hub/Holdings.sol";
import {AccountId} from "../../../src/core/types/AccountId.sol";
import {Accounting} from "../../../src/core/hub/Accounting.sol";
import {Gateway} from "../../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../../src/core/hub/HubHandler.sol";
import {RequestId} from "../../../src/core/types/RequestId.sol";
import {HubRegistry} from "../../../src/core/hub/HubRegistry.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {SpokeHandler} from "../../../src/core/spoke/SpokeHandler.sol";
import {IEscrow} from "../../../src/core/spoke/interfaces/IEscrow.sol";
import {AssetId, newAssetId} from "../../../src/core/types/AssetId.sol";
import {SnapshotQueue} from "../../../src/core/spoke/SnapshotQueue.sol";
import {SpokeRegistry} from "../../../src/core/spoke/SpokeRegistry.sol";
import {MultiAdapter} from "../../../src/core/messaging/MultiAdapter.sol";
import {ShareClassManager} from "../../../src/core/hub/ShareClassManager.sol";
import {ISnapshotHook} from "../../../src/core/hub/interfaces/ISnapshotHook.sol";
import {EscrowFactory} from "../../../src/core/spoke/factories/EscrowFactory.sol";
import {MessageProcessor} from "../../../src/core/messaging/MessageProcessor.sol";
import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";
import {IHubRequestManager} from "../../../src/core/hub/interfaces/IHubRequestManager.sol";
import {IProtocolPauser} from "../../../src/core/messaging/interfaces/IProtocolPauser.sol";
import {ManagerKind, VaultUpdateKind} from "../../../src/core/messaging/libraries/MessageLib.sol";

import {VaultRequestRouter} from "../../../src/vaults/messaging/VaultRequestRouter.sol";

import {Root} from "../../../src/admin/Root.sol";
import {GasService} from "../../../src/admin/GasService.sol";

import {HookPolicies} from "../../../src/token/hooks/HookPolicies.sol";
import {NAVManager} from "../../../src/hooks/accounting/NAVManager.sol";
import {ShareTokenHook} from "../../../src/token/hooks/ShareTokenHook.sol";
import {INAVManager} from "../../../src/hooks/accounting/interfaces/INAVManager.sol";
import {SimplePriceManager} from "../../../src/hooks/accounting/SimplePriceManager.sol";
import {UpdateRestrictionMessageLib} from "../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {AccountingToken} from "../../../src/managers/spoke/AccountingToken.sol";

import {OracleValuation} from "../../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../../src/valuations/IdentityValuation.sol";

import {OrderBook} from "../../../src/vaults/hub/OrderBook.sol";
import {VaultRouter} from "../../../src/vaults/VaultRouter.sol";
import {SpokeOracle} from "../../../src/vaults/oracles/SpokeOracle.sol";
import {VaultFactory} from "../../../src/vaults/factories/VaultFactory.sol";
import {FeeRequestManager} from "../../../src/vaults/hub/FeeRequestManager.sol";
import {IVaultOracle} from "../../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {VaultRequestIdLib} from "../../../src/vaults/libraries/VaultRequestIdLib.sol";
import {IAsyncVault, VaultPlugins} from "../../../src/vaults/interfaces/IAsyncVault.sol";
import {BasinLiquidityRoute} from "../../../src/vaults/liquidity/BasinLiquidityRoute.sol";
import {VaultLiquidityRoute} from "../../../src/vaults/liquidity/VaultLiquidityRoute.sol";
import {ReserveInstantPolicy} from "../../../src/vaults/policies/ReserveInstantPolicy.sol";
import {IVaultLiquidityRoute} from "../../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";
import {PerRequestPolicy, PerPeriodPolicy, PerInvestorPolicy} from "../../../src/vaults/policies/RequestPolicies.sol";
import {
    IInstantPolicy,
    ILiquidityRoute,
    IRequestPolicy,
    IReserveInstantPolicy,
    ISettlementObserver
} from "../../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {vm} from "@chimera/Hevm.sol";
import {BaseSetup} from "@chimera/BaseSetup.sol";
import {USD_ID} from "../../../src/deployment/Currencies.sol";
import {SubsidyManager} from "../../../src/utils/SubsidyManager.sol";
import {StdHubPolicy} from "../../../src/policies/hub/StdHubPolicy.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {RefundEscrowFactory} from "../../../src/utils/RefundEscrowFactory.sol";
import {ShareTokenRegistrar} from "../../../src/token/ShareTokenRegistrar.sol";
import {IStdHubPolicy} from "../../../src/policies/hub/interfaces/IStdHubPolicy.sol";
import {IShareTokenRegistrar} from "../../../src/token/interfaces/IShareTokenRegistrar.sol";

/// @notice Brings up the whole protocol on one chain, the way the deployer wires it, with the Vault
///         Development Kit on top. Hub and spoke share a centrifuge id, so every message is applied in
///         the call that sends it and hub-side and spoke-side ledgers can be compared at any point.
/// @dev    Three pools:
///         - Pool A, the one the fuzzer drives: USDC and pool C's share token as assets, four vaults
///           (per-request, per-period, instant backed by `VaultLiquidityRoute`, per-investor instant
///           backed by `BasinLiquidityRoute` over a mock venue).
///         - Pool C, the fund pool A holds: an instant vault the liquidity route redeems on demand.
///         - Pool B, configured with live positions in setup and never targeted, so any write the
///           fuzzer reaches into it is a pool-isolation failure.
///         Only `vm.prank`, `vm.warp` and `vm.deal` are used, so Echidna and Medusa run it as is.
abstract contract Setup is BaseSetup {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    uint16 internal constant CENTRIFUGE_ID = 1;
    uint128 internal constant GAS = 0.1 ether;
    // Swap these two to run the whole suite on other decimals: the asset's and the pool currency's (which
    // is the share token's). Every amount below and in the targets derives from the units that follow.
    uint8 internal constant SHARE_DECIMALS = 18;
    uint8 internal constant USDC_DECIMALS = 6;
    uint128 internal constant ONE_ASSET = uint128(10 ** USDC_DECIMALS);
    uint128 internal constant ONE_SHARE = uint128(10 ** SHARE_DECIMALS);
    /// @dev What a conversion rounds away: a thousandth of a unit, at least one wei.
    uint128 internal constant DUST_ASSETS = ONE_ASSET >= 1000 ? ONE_ASSET / 1000 : 1;
    uint128 internal constant DUST_SHARES = ONE_SHARE >= 1000 ? ONE_SHARE / 1000 : 1;
    uint128 internal constant ACTOR_FUNDS = 1_000_000_000 * ONE_ASSET;
    uint128 internal constant VENUE_FUNDS = 10_000_000 * ONE_ASSET;
    uint64 internal constant PERIOD = 1 hours;
    uint64 internal constant ORACLE_MAX_AGE = 1 days;
    uint64 internal constant ORACLE_MAX_SKEW = 12 hours;

    AccountId internal constant ASSET_ACCOUNT = AccountId.wrap(1);
    AccountId internal constant EQUITY_ACCOUNT = AccountId.wrap(2);
    AccountId internal constant LOSS_ACCOUNT = AccountId.wrap(3);
    AccountId internal constant GAIN_ACCOUNT = AccountId.wrap(4);

    // Roles
    address internal constant FM = address(0xF000);
    address internal constant BSM = address(0xB000);
    address internal constant FEEDER = address(0xFEED);
    address internal constant LP = address(0x1A00);
    address internal constant REFUND = address(0xEEF0);
    address internal constant OUTSIDER = address(0xBAD0);
    address internal constant AUX_MANAGER = address(0xA0C0);
    address internal constant FEE_RECIPIENT = address(0xFEE0);
    /// @dev The account that pays the rebates of `rebateVault`, funded and tracked like every other holder of USDC.
    address internal constant REBATER = address(0xBA7E);
    address internal constant INVESTOR_B = address(0xB0B0);
    // Pool isolation: the adversary's manager and investor, and the manager pool B is handed to
    address internal constant MALLORY = address(0xD000);
    address internal constant INVESTOR_D = address(0xD0D0);
    address internal constant MANAGER_B = address(0xB001);

    // Core
    Root internal root;
    GasService internal gasService;
    Gateway internal gateway;
    MultiAdapter internal multiAdapter;
    Envoy internal envoy;
    MessageProcessor internal messageProcessor;
    MessageDispatcher internal messageDispatcher;
    ShareTokenRegistrar internal shareTokenRegistrar;
    EscrowFactory internal escrowFactory;
    SpokeRegistry internal spokeRegistry;
    SnapshotQueue internal snapshotQueue;
    Spoke internal spoke;
    SpokeHandler internal spokeHandler;
    HubRegistry internal hubRegistry;
    Accounting internal accounting;
    Holdings internal holdings;
    ShareClassManager internal shareClassManager;
    Hub internal hub;
    HubHandler internal hubHandler;

    // Periphery
    RefundEscrowFactory internal refundEscrowFactory;
    SubsidyManager internal subsidyManager;
    ShareTokenHook internal fullRestrictions;
    ShareTokenHook internal freezeOnly;
    IdentityValuation internal identityValuation;
    OracleValuation internal oracleValuation;

    // Vault Development Kit
    OrderBook internal orderBook;
    FeeRequestManager internal feeRequestManager;
    VaultFactory internal vaultFactory;
    VaultRequestRouter internal vaultRouter;
    VaultRouter internal investorRouter;
    CountingObserver internal requestObserver;
    RevertingObserver internal refusingObserver;
    SpokeOracle internal spokeOracle;
    PerRequestPolicy internal perRequestPolicy;
    PerInvestorPolicy internal perInvestorPolicy;
    PerPeriodPolicy internal perPeriodPolicy;
    StdHubPolicy internal hubPolicy;
    ReserveInstantPolicy internal reserveInstantPolicy;
    VaultLiquidityRoute internal vaultRoute;
    BasinLiquidityRoute internal basinRoute;
    AccountingToken internal accountingToken;
    ERC20Basin internal basin;

    // Pools
    ERC20 internal usdc;
    AssetId internal usdcId;
    AssetId internal cShareId;
    AssetId internal basinLiabilityId;
    PoolId internal poolA;
    PoolId internal poolB;
    PoolId internal poolC;
    PoolId internal poolD;
    ShareClassId internal scA;
    ShareClassId internal scB;
    ShareClassId internal scC;
    ShareClassId internal scD;
    IShareToken internal shareA;
    IShareToken internal shareB;
    IShareToken internal shareC;
    IShareToken internal shareD;

    // Vaults on pool A, and the single vaults on pools B and C
    IAsyncVault[] internal vaults;
    IAsyncVault internal vaultB;
    IAsyncVault internal vaultC;
    IAsyncVault internal vaultD;

    // Pool E: a pool whose only vault holds an asset registered under another network's id, the one case the request
    // router pays a message out of the pool's subsidy
    uint16 internal constant REMOTE_ID = CENTRIFUGE_ID + 1;
    PoolId internal poolE;
    ShareClassId internal scE;
    IShareToken internal shareE;
    ERC20 internal usdcE;
    AssetId internal usdcEId;
    IAsyncVault internal vaultE;

    address[] internal actors;
    bytes32 internal footprintB;
    bytes32 internal footprintD;
    EvilVaultFactory internal evilFactory;
    /// @dev A pool C vault the liquidity route may draw on that answers as its mode says (see `HostileUnderlying`).
    HostileUnderlying internal hostileUnderlying;
    /// @dev A pool A vault whose only route is `hostileUnderlying`. The route refuses two vaults on one share class in
    ///      one list, which would count the position twice, so the hostile one has a top vault of its own.
    IAsyncVault internal hostileTop;
    /// @dev A pool A vault whose instant policy rebates every trade (the shipped policy never does), outside `vaults`.
    /// @dev Who the handlers made a sponsor of a vault, kept apart from the policy's own list so the consent property
    ///      does not ask the contract under test
    mapping(address vault => mapping(address who => bool)) internal ghostSponsor;
    IAsyncVault internal rebateVault;

    // The NAV pool: a pool of its own whose networks are logical ids that nothing is deployed on, reported to the
    // hub as a spoke would, through the hub handler. Its NAV is signed per network and summed by the price manager.
    uint16 internal constant NAV_NET_A = 5;
    uint16 internal constant NAV_NET_B = 6;
    NAVManager internal navManager;
    SimplePriceManager internal priceManager;
    PoolId internal poolN;
    ShareClassId internal scN;
    /// @dev Three assets with different decimals and a liability, on two networks
    AssetId[4] internal navAssets;
    uint8[4] internal navDecimals;

    /// @dev Raw amount of each asset the messages put in the holding
    uint256[4] internal ghostNavAmount;
    mapping(uint16 net => uint128) internal ghostNavShares;
    mapping(uint16 net => uint64) internal ghostNavNonce;
    /// @dev What the network's NAV and shares were at its last snapshot, the values the price manager must hold
    mapping(uint16 net => bool) internal ghostNavSynced;
    mapping(uint16 net => int256) internal ghostNavSyncedNav;
    mapping(uint16 net => uint128) internal ghostNavSyncedShares;
    /// @dev A vault of share class A that the registry holds under a second share class of the same pool
    IAsyncVault internal misfiledVault;

    function setup() internal virtual override {
        actors.push(address(0x10000));
        actors.push(address(0x20000));
        actors.push(address(0x30000));

        _deployCore();
        _wireCore();
        _deployPeriphery();

        usdc = new ERC20(USDC_DECIMALS);
        vm.prank(OUTSIDER);
        spoke.registerAsset(CENTRIFUGE_ID, address(usdc), 0, REFUND);
        usdcId = newAssetId(CENTRIFUGE_ID, 1);

        poolA = hubRegistry.poolId(CENTRIFUGE_ID, 1);
        poolC = hubRegistry.poolId(CENTRIFUGE_ID, 2);
        poolB = hubRegistry.poolId(CENTRIFUGE_ID, 3);
        scA = _createPool(poolA, address(fullRestrictions), true);
        scC = _createPool(poolC, address(freezeOnly), false);
        scB = _createPool(poolB, address(fullRestrictions), true);
        shareA = IShareToken(address(spokeRegistry.shareToken(poolA, scA)));
        shareB = IShareToken(address(spokeRegistry.shareToken(poolB, scB)));
        shareC = IShareToken(address(spokeRegistry.shareToken(poolC, scC)));

        _deployVaults();
        _deployNavPool();
        _fundActors();
        _setupAdversarialPools();
        footprintB = _footprintB();
        footprintD = _footprintD();
        _setupRemoteAssetPool();
    }

    //----------------------------------------------------------------------------------------------
    // Deployment
    //----------------------------------------------------------------------------------------------

    function _deployCore() internal {
        address self = address(this);
        uint8[32] memory txLimits;

        root = new Root(0, self);
        gasService = new GasService(txLimits, CENTRIFUGE_ID);
        gateway = new Gateway(CENTRIFUGE_ID, IProtocolPauser(address(root)), self);
        multiAdapter = new MultiAdapter(CENTRIFUGE_ID, gateway, self);
        envoy = new Envoy(self);
        messageProcessor = new MessageProcessor(root, self);
        messageDispatcher = new MessageDispatcher(CENTRIFUGE_ID, root, gateway, self);
        shareTokenRegistrar = new ShareTokenRegistrar(address(root), self);
        escrowFactory = new EscrowFactory(address(root), self);
        spokeRegistry = new SpokeRegistry(self);
        snapshotQueue = new SnapshotQueue(self);
        spoke = new Spoke(gateway, snapshotQueue, spokeRegistry, escrowFactory, self);
        spokeHandler = new SpokeHandler(spokeRegistry, escrowFactory, self);
        hubRegistry = new HubRegistry(self);
        accounting = new Accounting(self);
        holdings = new Holdings(hubRegistry, self);
        shareClassManager = new ShareClassManager(hubRegistry, self);
        hub = new Hub(gateway, holdings, accounting, hubRegistry, multiAdapter, shareClassManager, self);
        hubHandler = new HubHandler(hub, holdings, hubRegistry, shareClassManager, self);
    }

    /// @dev The subset of `CoreActionBatcher` a single-chain deployment exercises.
    function _wireCore() internal {
        multiAdapter.rely(address(gateway));
        messageProcessor.rely(address(gateway));
        gateway.rely(address(multiAdapter));

        gateway.rely(address(messageDispatcher));
        multiAdapter.rely(address(messageDispatcher));
        envoy.rely(address(messageDispatcher));
        hubHandler.rely(address(messageDispatcher));
        root.rely(address(messageDispatcher));

        gateway.rely(address(messageProcessor));
        multiAdapter.rely(address(messageProcessor));
        hubHandler.rely(address(messageProcessor));
        envoy.rely(address(messageProcessor));

        messageDispatcher.rely(address(spoke));
        snapshotQueue.rely(address(spoke));

        spokeHandler.rely(address(messageProcessor));
        spokeHandler.rely(address(messageDispatcher));
        escrowFactory.rely(address(spokeHandler));

        shareTokenRegistrar.rely(address(spokeHandler));
        shareTokenRegistrar.rely(address(spoke));

        spokeRegistry.rely(address(spokeHandler));
        spokeRegistry.rely(address(spoke));

        multiAdapter.rely(address(hub));
        accounting.rely(address(hub));
        holdings.rely(address(hub));
        hubRegistry.rely(address(hub));
        shareClassManager.rely(address(hub));
        messageDispatcher.rely(address(hub));

        hubRegistry.rely(address(hubHandler));
        holdings.rely(address(hubHandler));
        shareClassManager.rely(address(hubHandler));
        hub.rely(address(hubHandler));
        messageDispatcher.rely(address(hubHandler));

        gateway.file("adapter", address(multiAdapter));
        gateway.file("messageGas", address(gasService));
        gateway.file("processor", address(messageProcessor));
        multiAdapter.file("parser", address(messageProcessor));
        multiAdapter.file("messageGas", address(gasService));

        messageDispatcher.file("spokeHandler", address(spokeHandler));
        messageDispatcher.file("multiAdapter", address(multiAdapter));
        messageDispatcher.file("envoy", address(envoy));
        messageDispatcher.file("hubHandler", address(hubHandler));

        messageProcessor.file("multiAdapter", address(multiAdapter));
        messageProcessor.file("gateway", address(gateway));
        messageProcessor.file("spokeHandler", address(spokeHandler));
        messageProcessor.file("envoy", address(envoy));
        messageProcessor.file("hubHandler", address(hubHandler));

        escrowFactory.file("spoke", address(spoke));
        shareTokenRegistrar.file("envoy", address(envoy));
        shareTokenRegistrar.file("spokeRegistry", address(spokeRegistry));
        spoke.file("sender", address(messageDispatcher));
        hub.file("sender", address(messageDispatcher));
        hubHandler.file("sender", address(messageDispatcher));

        root.endorse(address(spoke));
        hubRegistry.registerAsset(USD_ID, SHARE_DECIMALS);
    }

    function _deployPeriphery() internal {
        address self = address(this);

        refundEscrowFactory = new RefundEscrowFactory(self);
        subsidyManager = new SubsidyManager(refundEscrowFactory, self);
        refundEscrowFactory.rely(address(subsidyManager));
        refundEscrowFactory.file("controller", address(subsidyManager));
        refundEscrowFactory.file("root", address(root));
        subsidyManager.file("envoy", address(envoy));

        fullRestrictions = new ShareTokenHook(
            address(root),
            address(envoy),
            address(spokeRegistry),
            address(spoke),
            address(spokeHandler),
            self,
            address(escrowFactory),
            HookPolicies.fullRestrictions()
        );
        freezeOnly = new ShareTokenHook(
            address(root),
            address(envoy),
            address(spokeRegistry),
            address(spoke),
            address(spokeHandler),
            self,
            address(escrowFactory),
            HookPolicies.freezeOnly()
        );
        fullRestrictions.rely(address(shareTokenRegistrar));
        freezeOnly.rely(address(shareTokenRegistrar));

        identityValuation = new IdentityValuation(hubRegistry);
        oracleValuation = new OracleValuation(hub, hubRegistry, address(envoy));

        orderBook = new OrderBook(hubRegistry, hub, gateway, address(envoy), self);
        orderBook.rely(address(hubHandler));
        feeRequestManager = new FeeRequestManager(hub, orderBook, address(envoy), gateway);

        vaultFactory = new VaultFactory(address(root), spoke, spokeRegistry);
        vaultRouter = new VaultRequestRouter(spoke, spokeRegistry, subsidyManager, address(envoy), self);
        vaultRouter.rely(address(spokeHandler));
        subsidyManager.rely(address(vaultRouter));

        spokeOracle = new SpokeOracle(spokeRegistry, ORACLE_MAX_AGE, ORACLE_MAX_SKEW, address(envoy));
        perRequestPolicy = new PerRequestPolicy(true);
        perInvestorPolicy = new PerInvestorPolicy();
        perPeriodPolicy = new PerPeriodPolicy(PERIOD, 0, 0, 0);
        investorRouter = new VaultRouter(spoke, spokeRegistry, self);
        requestObserver = new CountingObserver();
        refusingObserver = new RevertingObserver();
        // As deployed, the investor router is endorsed: it pays and relays for the investor and is no member
        root.endorse(address(investorRouter));
        hubPolicy = _newHubPolicy();
        reserveInstantPolicy = new ReserveInstantPolicy(spoke, address(envoy));
        vaultRoute = new VaultLiquidityRoute(spoke, address(envoy), address(root));
    }

    /// @dev A pool with one share class over USDC, notified to the spoke, with the OrderBook as its
    ///      request manager, the FeeRequestManager as a hub manager, the BSM as a balance-sheet
    ///      manager and the oracle valuation pricing its USDC holding when `priced`.
    function _createPool(PoolId poolId, address hook, bool priced) internal returns (ShareClassId scId) {
        hub.createPool(poolId, FM, USD_ID);
        scId = shareClassManager.previewNextShareClassId(poolId);

        vm.prank(FM);
        hub.addShareClass(poolId, "Share", "SHR", bytes32(bytes8(poolId.raw())));
        _createAccounts(poolId);
        _fm();
        hub.notifyPool(poolId, CENTRIFUGE_ID, REFUND);
        _fm();
        hub.notifyShareClass(poolId, scId, CENTRIFUGE_ID, address(shareTokenRegistrar).toBytes32(), "", 0, REFUND);
        _managerCall(
            poolId,
            address(shareTokenRegistrar),
            abi.encode(uint8(IShareTokenRegistrar.RegistrarCall.SetHook), scId, hook)
        );
        _fm();
        hub.initializeHolding(poolId, scId, usdcId, identityValuation, _accounts());
        _updateManager(poolId, BSM, true);
        _fm();
        hub.setRequestManager(
            poolId, CENTRIFUGE_ID, IHubRequestManager(address(orderBook)), address(vaultRouter).toBytes32(), REFUND
        );
        _fm();
        hub.updateHubManager(poolId, address(feeRequestManager), true);

        if (priced) {
            _managerCall(poolId, address(oracleValuation), abi.encode(uint16(0), FEEDER.toBytes32(), true));
            _fm();
            hub.updateHubManager(poolId, address(oracleValuation), true);
            vm.prank(FEEDER);
            oracleValuation.setPrice(poolId, scId, usdcId, d18(1, 1));
            _fm();
            hub.updateHoldingValuation(poolId, scId, usdcId, oracleValuation);
        }
        _pushPrices(poolId, scId, d18(1, 1));
    }

    function _createAccounts(PoolId poolId) internal {
        vm.prank(FM);
        hub.createAccount(poolId, ASSET_ACCOUNT, true);
        vm.prank(FM);
        hub.createAccount(poolId, EQUITY_ACCOUNT, false);
        vm.prank(FM);
        hub.createAccount(poolId, GAIN_ACCOUNT, false);
        vm.prank(FM);
        hub.createAccount(poolId, LOSS_ACCOUNT, true);
    }

    function _accounts() internal pure returns (AccountId[4] memory a) {
        a[0] = ASSET_ACCOUNT;
        a[1] = EQUITY_ACCOUNT;
        a[2] = GAIN_ACCOUNT;
        a[3] = LOSS_ACCOUNT;
    }

    function _deployVaults() internal {
        // Pool C: the fund pool A invests in, exited instantly on demand by pool A's liquidity route
        vaultC = _deployVault(poolC, scC, _plugins(perRequestPolicy, true, address(0)));
        _openInstantLane(poolC, vaultC, 0, false);

        // Pool A
        vaults.push(_deployVault(poolA, scA, _plugins(perRequestPolicy, false, address(0))));
        VaultPlugins memory perPeriod = _plugins(perRequestPolicy, false, address(0));
        perPeriod.requestPolicy = perPeriodPolicy;
        // A short horizon, so own requests evict unsettled windows and keepers have work
        vaults.push(_deployVault(poolA, scA, perPeriod, 4));
        vaults.push(_deployVault(poolA, scA, _plugins(perRequestPolicy, true, address(vaultRoute))));

        basin = new ERC20Basin(usdc, LP);
        accountingToken = new AccountingToken(address(envoy));
        basinRoute = new BasinLiquidityRoute(basin, spoke, address(envoy), accountingToken, address(root));
        VaultPlugins memory perInvestor = _plugins(perRequestPolicy, true, address(basinRoute));
        perInvestor.requestPolicy = perInvestorPolicy;
        vaults.push(_deployVault(poolA, scA, perInvestor));

        // A horizon of 8, past what the controller's own slot holds, so the overflow slots are reached
        vaults.push(_deployVault(poolA, scA, perPeriod, 8));

        _openInstantLane(poolA, vaults[2], 50, false);
        _openInstantLane(poolA, vaults[3], 20, true);

        // A vault whose instant policy rebates every trade, paid by an account that has approved it
        VaultPlugins memory rebating = _plugins(perRequestPolicy, false, address(0));
        rebating.instantPolicy = IInstantPolicy(address(new RebatingInstantPolicy(REBATER, 25)));
        rebateVault = _deployVault(poolA, scA, rebating);
        usdc.mint(REBATER, 1_000_000 * ONE_ASSET);
        vm.prank(REBATER);
        usdc.approve(address(rebateVault), type(uint256).max);

        // Pool C's share token is a pool A asset, released by the route as a balance-sheet manager
        vm.prank(OUTSIDER);
        spoke.registerAsset(CENTRIFUGE_ID, address(shareC), 0, REFUND);
        cShareId = newAssetId(CENTRIFUGE_ID, 2);
        _fm();
        hub.initializeHolding(poolA, scA, cShareId, identityValuation, _accounts());
        _updateManager(poolA, address(vaultRoute), true);
        // Pool C also registers a vault of its own making that a second pool A vault is told to draw on: the route has
        // to treat what it reads from it as hostile
        hostileUnderlying = new HostileUnderlying(poolC.raw());
        hostileTop = _deployVault(poolA, scA, _plugins(perRequestPolicy, true, address(vaultRoute)));
        _openInstantLane(poolA, hostileTop, 0, false);
        EvilVaultFactory hostileFactory = new EvilVaultFactory();
        hostileFactory.set(address(hostileUnderlying));
        _fm();
        hub.updateVault(
            poolC, scC, usdcId, address(hostileFactory).toBytes32(), VaultUpdateKind.DeployAndLink, "", 0, REFUND
        );
        require(spokeRegistry.isLinked(address(hostileUnderlying)), "hostile underlying not linked");
        _managerCall(
            poolC,
            address(vaultRoute),
            abi.encode(
                IVaultLiquidityRoute.ConfigKind.Consent,
                address(hostileUnderlying),
                abi.encode(address(hostileTop), true)
            )
        );
        _managerCall(
            poolA,
            address(vaultRoute),
            abi.encode(
                IVaultLiquidityRoute.ConfigKind.Routes,
                address(hostileTop),
                abi.encode(_one(address(hostileUnderlying)))
            )
        );
        address[] memory underlying = _one(address(vaultC));
        // The underlying's own pool lets the top vault draw on it, then the top pool routes to it
        _managerCall(
            poolC,
            address(vaultRoute),
            abi.encode(IVaultLiquidityRoute.ConfigKind.Consent, address(vaultC), abi.encode(address(vaults[2]), true))
        );
        _managerCall(
            poolA,
            address(vaultRoute),
            abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, address(vaults[2]), abi.encode(underlying))
        );

        // The route books each draw as pool A's liability, as its balance-sheet manager and a minter
        _updateManager(poolA, address(basinRoute), true);
        _managerCall(poolA, address(accountingToken), abi.encode(address(basinRoute).toBytes32(), true));
        vm.prank(OUTSIDER);
        spoke.registerAsset(CENTRIFUGE_ID, address(accountingToken), _basinLiabilityTokenId(), REFUND);
        basinLiabilityId = newAssetId(CENTRIFUGE_ID, 3);

        // The basin's credit line: the pool's limit through the Envoy, the venue's credit from its LP
        _managerCall(poolA, address(basinRoute), abi.encode(address(vaults[3]), uint128(VENUE_FUNDS / 10)));
        vm.prank(LP);
        basinRoute.setCredit(address(vaults[3]), uint128(VENUE_FUNDS / 10));
        usdc.mint(address(basin), VENUE_FUNDS);
        basin.advertise(VENUE_FUNDS);

        // Pool B: never targeted after this
        vaultB = _deployVault(poolB, scB, _plugins(perRequestPolicy, false, address(0)));

        _misfileVault();
    }

    /// @dev Pool A gets a second share class, and a vault built for share class A is registered and linked under it.
    ///      The registry takes any contract from a pool's factory, so the vault must refuse a position that is not
    ///      its own, in the pool and the asset as well as the share class.
    function _misfileVault() internal {
        vm.prank(FM);
        hub.addShareClass(poolA, "Other", "OTH", bytes32(bytes8(poolA.raw())) | bytes32(uint256(2)));
        ShareClassId other = shareClassManager.previewNextShareClassId(poolA);
        other = ShareClassId.wrap(bytes16(uint128(ShareClassId.unwrap(other)) - 1));
        _fm();
        hub.notifyShareClass(poolA, other, CENTRIFUGE_ID, address(shareTokenRegistrar).toBytes32(), "", 0, REFUND);

        bytes memory payload =
            abi.encode(_plugins(perRequestPolicy, false, address(0)), uint64(vaults.length + 1), uint256(0));
        misfiledVault = IAsyncVault(vaultFactory.deploy(poolA, scA, address(usdc), 0, payload));
        spokeRegistry.registerVault(
            poolA, other, usdcId, address(usdc), 0, vaultFactory, address(misfiledVault), payload
        );
        spokeRegistry.linkVault(poolA, other, usdcId, address(misfiledVault));
        require(spokeRegistry.isLinked(address(misfiledVault)), "misfiled vault not linked");
    }

    /// @dev The policy a pool installs late: instant for what the fuzzer does within bounds (fills within the fee
    ///      bound, restriction updates, a pause), and held on the timelock for everything else, so once it is on,
    ///      the manager actions that are out of policy refuse and the FeeRequestManager's check runs.
    function _newHubPolicy() internal returns (StdHubPolicy) {
        IStdHubPolicy.Config memory c;
        c.delay = 1 hours;
        c.expiry = 1 days;
        c.escalation = 2 hours;
        c.isRestrictionUpdateInstant = true;
        c.spokeOracle = address(spokeOracle);
        c.oracleValuation = address(oracleValuation);
        c.orderBook = address(orderBook);
        c.maxFulfillPriceDeviation = type(uint128).max;
        c.maxFeeBps = 500;
        return new StdHubPolicy(hub, multiAdapter, shareClassManager, c);
    }

    function _basinLiabilityTokenId() internal view returns (uint256) {
        return accountingToken.toTokenId(poolA, address(usdc), true);
    }

    function _plugins(IRequestPolicy requestPolicy, bool instant, address route)
        internal
        view
        returns (VaultPlugins memory)
    {
        return VaultPlugins({
            oracle: IVaultOracle(address(spokeOracle)),
            instantPolicy: IInstantPolicy(instant ? address(reserveInstantPolicy) : address(0)),
            requestPolicy: requestPolicy,
            liquidityRoute: ILiquidityRoute(route),
            settlementObserver: ISettlementObserver(address(0))
        });
    }

    /// @dev Pool N: two logical networks, three assets of 6, 12 and 14 decimals and a liability, valued 1:1.
    function _deployNavPool() internal {
        navManager = new NAVManager(hub, address(envoy));
        priceManager = new SimplePriceManager(hub, address(navManager));

        navDecimals = [6, 12, 14, 18];
        navAssets =
            [newAssetId(NAV_NET_B, 1), newAssetId(NAV_NET_B, 2), newAssetId(NAV_NET_A, 1), newAssetId(NAV_NET_A, 2)];
        for (uint256 i; i < 4; i++) {
            hubRegistry.registerAsset(navAssets[i], navDecimals[i]);
        }

        poolN = hubRegistry.poolId(CENTRIFUGE_ID, 50);
        hub.createPool(poolN, FM, USD_ID);
        scN = shareClassManager.previewNextShareClassId(poolN);
        vm.prank(FM);
        hub.addShareClass(poolN, "Nav", "NAV", bytes32(bytes8(poolN.raw())));
        _fm();
        hub.setSnapshotHook(poolN, ISnapshotHook(address(navManager)));
        _fm();
        hub.updateHubManager(poolN, address(navManager), true);
        _fm();
        hub.updateHubManager(poolN, address(priceManager), true);

        _navCall(abi.encode(uint8(INAVManager.ManagerCall.SetNavHook), address(priceManager)));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.SetDefaultValuation), address(identityValuation)));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NAV_NET_A));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), NAV_NET_B));
        for (uint256 i; i < 3; i++) {
            _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), scN, navAssets[i]));
        }
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeLiability), scN, navAssets[3]));
    }

    /// @dev The network's NAV from the raw amounts: assets scaled to 18 decimals, less the liability, which has no
    ///      gain or loss since every valuation is 1:1
    function _ghostNav(uint16 net) internal view returns (int256 nav) {
        for (uint256 i; i < 4; i++) {
            if (navAssets[i].centrifugeId() != net) continue;
            int256 value = int256(ghostNavAmount[i] * 10 ** (18 - navDecimals[i]));
            nav += i == 3 ? -value : value;
        }
    }

    function _navCall(bytes memory payload) internal {
        _fm();
        hub.managerCall(poolN, CENTRIFUGE_ID, address(navManager).toBytes32(), payload, 0, 0, REFUND);
    }

    /// @dev At the policy's default horizon: 1 for the non-batching request policies.
    function _deployVault(PoolId poolId, ShareClassId scId, VaultPlugins memory plugins)
        internal
        returns (IAsyncVault vault)
    {
        return _deployVault(poolId, scId, plugins, 0);
    }

    function _deployVault(PoolId poolId, ShareClassId scId, VaultPlugins memory plugins, uint256 foldHorizon)
        internal
        returns (IAsyncVault vault)
    {
        bytes memory payload = abi.encode(plugins, uint64(vaults.length), foldHorizon);
        vault = IAsyncVault(vaultFactory.deploy(poolId, scId, address(usdc), 0, payload));
        _fm();
        hub.updateVault(
            poolId, scId, usdcId, address(vaultFactory).toBytes32(), VaultUpdateKind.DeployAndLink, payload, 0, REFUND
        );
        require(spokeRegistry.isLinked(address(vault)), "vault not linked");
        _updateManager(poolId, address(vault), true);
    }

    /// @dev A fee with no recipient is retained in the escrow, so `retained` covers both legs between vaults.
    function _openInstantLane(PoolId poolId, IAsyncVault vault, uint16 feeBps, bool retained) internal {
        bytes memory terms =
            abi.encode(retained ? address(0) : FEE_RECIPIENT, feeBps, feeBps, true, false, false, uint128(ACTOR_FUNDS));
        _managerCall(
            poolId,
            address(reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(vault), terms)
        );
    }

    /// @dev Every actor is a pool A member funded with USDC. Pool B is given a settled-and-claimed deposit,
    ///      a part-filled one still outstanding and a pending redemption, so its footprint covers every
    ///      ledger a stray write could land in.
    function _fundActors() internal {
        for (uint256 i; i < actors.length; i++) {
            usdc.mint(actors[i], ACTOR_FUNDS);
            _updateRestriction(poolA, scA, _memberMsg(actors[i]));
        }
        usdc.mint(BSM, ACTOR_FUNDS);
        _updateRestriction(poolA, scA, _memberMsg(BSM));

        usdc.mint(INVESTOR_B, ACTOR_FUNDS);
        _updateRestriction(poolB, scB, _memberMsg(INVESTOR_B));
        uint256 first = _request(vaultB, INVESTOR_B, 10_000 * ONE_ASSET);
        _fulfillB(first, 10_000 * ONE_ASSET);
        uint256 claimable = vaultB.maxMint(INVESTOR_B);
        vm.prank(INVESTOR_B);
        vaultB.mint(claimable, INVESTOR_B, INVESTOR_B);
        vm.prank(INVESTOR_B);
        vaultB.requestRedeem(claimable / 2, INVESTOR_B, INVESTOR_B);
        _fulfillB(_request(vaultB, INVESTOR_B, 4_000 * ONE_ASSET), 2_000 * ONE_ASSET);
    }

    function _request(IAsyncVault vault, address investor, uint128 amount) internal returns (uint256 requestId) {
        vm.prank(investor);
        usdc.approve(address(vault), amount);
        vm.prank(investor);
        requestId = vault.requestDeposit(amount, investor, investor);
    }

    function _fulfillB(uint256 requestId, uint128 amount) internal {
        _fm();
        feeRequestManager.fulfill(poolB, scB, usdcId, RequestId.wrap(requestId), true, amount, 0, REFUND);
    }

    //----------------------------------------------------------------------------------------------
    // Manager helpers
    //----------------------------------------------------------------------------------------------

    /// @dev Pranks the pool manager for the next call. Same-chain messages cost nothing, but the
    ///      manager still carries ETH so a call that forwards value has it to forward.
    function _fm() internal {
        vm.deal(FM, 1 ether);
        vm.prank(FM);
    }

    /// @dev Once the standard policy governs the pool, a manager call outside it waits for an authorization to age.
    ///      Schedules `data`, the hub call exactly as the manager sends it, and lets it mature, so the call that
    ///      follows goes through. A call in policy, or one the policy blocks outright, has nothing to wait for.
    function _authorize(PoolId poolId, bytes memory data) internal {
        if (address(hubRegistry.policy(poolId)) != address(hubPolicy)) return;
        try hubRegistry.initiateAuthorization(poolId, FM, data) {} catch {}
        uint256 validAfter = hubRegistry.authorizedAfter(hubRegistry.authId(poolId, data));
        if (validAfter > block.timestamp) vm.warp(validAfter);
    }

    /// @dev Lets a manager call wait out its authorization now, so a handler that compares state before and after
    ///      its calls does not see the wait (a lapsing membership moves with it).
    function _authorizeManagerCall(PoolId poolId, address target, bytes memory payload) internal {
        _authorize(
            poolId, abi.encodeCall(hub.managerCall, (poolId, CENTRIFUGE_ID, target.toBytes32(), payload, 0, 0, REFUND))
        );
    }

    function _managerCall(PoolId poolId, address target, bytes memory payload) internal {
        _authorizeManagerCall(poolId, target, payload);
        _fm();
        hub.managerCall(poolId, CENTRIFUGE_ID, target.toBytes32(), payload, 0, 0, REFUND);
    }

    function _updateManager(PoolId poolId, address who, bool canManage) internal {
        _authorize(
            poolId,
            abi.encodeCall(
                hub.updateManager, (poolId, CENTRIFUGE_ID, ManagerKind.Spoke, who.toBytes32(), canManage, REFUND)
            )
        );
        _fm();
        hub.updateManager(poolId, CENTRIFUGE_ID, ManagerKind.Spoke, who.toBytes32(), canManage, REFUND);
    }

    function _updateRestriction(PoolId poolId, ShareClassId scId, bytes memory payload) internal {
        _authorize(poolId, abi.encodeCall(hub.updateRestriction, (poolId, scId, CENTRIFUGE_ID, payload, 0, REFUND)));
        _fm();
        hub.updateRestriction(poolId, scId, CENTRIFUGE_ID, payload, 0, REFUND);
    }

    function _memberMsg(address user) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
            user: user.toBytes32(), validUntil: type(uint64).max
        }).serialize();
    }

    function _pushPrices(PoolId poolId, ShareClassId scId, D18 pricePoolPerShare) internal {
        _fm();
        hub.updateSharePrice(poolId, scId, pricePoolPerShare, uint64(block.timestamp));
        _fm();
        hub.notifySharePrice(poolId, scId, CENTRIFUGE_ID, REFUND);
        _fm();
        hub.notifyAssetPrice(poolId, scId, usdcId, REFUND);
    }

    function _escrow(PoolId poolId) internal view returns (IEscrow) {
        return spoke.escrow(poolId);
    }

    //----------------------------------------------------------------------------------------------
    // Pool isolation: pools B and D, and the footprints that watch them
    //----------------------------------------------------------------------------------------------

    /// @dev Pool B is configured with live positions and handed to its own manager. Pool D is the adversary: it
    ///      has its own manager (`MALLORY`, a hub and spoke manager of D alone), its own share class and an
    ///      instant vault from the canonical factory, and holds real deposits, so a write that crosses a pool
    ///      boundary in either direction shows in a footprint. D shares the singletons (OrderBook,
    ///      FeeRequestManager, request router, plugins) with every other pool, as a pool does.
    ///      Neither FM nor the BSM manages B or D from here on: they hold roles on A (and C) only, so any
    ///      effect they reach on B or D is a boundary crossing, not an exercise of their own authority.
    function _setupAdversarialPools() internal {
        evilFactory = new EvilVaultFactory();
        poolD = hubRegistry.poolId(CENTRIFUGE_ID, 4);
        scD = _createPool(poolD, address(fullRestrictions), true);
        shareD = IShareToken(address(spokeRegistry.shareToken(poolD, scD)));
        vaultD = _deployVault(poolD, scD, _plugins(perRequestPolicy, true, address(0)));
        _openInstantLane(poolD, vaultD, 25, false);

        usdc.mint(INVESTOR_D, ACTOR_FUNDS);
        _updateRestriction(poolD, scD, _memberMsg(INVESTOR_D));
        uint256 first = _request(vaultD, INVESTOR_D, 1e10);
        _fulfillD(first, 1e10);
        uint256 claimable = vaultD.maxMint(INVESTOR_D);
        vm.prank(INVESTOR_D);
        vaultD.mint(claimable, INVESTOR_D, INVESTOR_D);
        vm.prank(INVESTOR_D);
        vaultD.requestRedeem(claimable / 2, INVESTOR_D, INVESTOR_D);
        _submitQueues(poolD, scD, address(vaultD));
        _fulfillD(_request(vaultD, INVESTOR_D, 4e9), 2e9);
        // Pool B's queues are submitted too, so the hub's holding and issuance carry its positions and a
        // stray write has a hub-side number to change; D's second request leaves its queue non-empty
        _submitQueues(poolB, scB, address(vaultB));

        _handOver(poolB, MANAGER_B, false);
        _handOver(poolD, MALLORY, true);
        vm.deal(MALLORY, 1 ether);
        vm.deal(MANAGER_B, 1 ether);
    }

    /// @dev The router sends a request paid from the pool's subsidy when the asset's network is not the pool's. The suite
    ///      has one network, so pool E registers its asset under `REMOTE_ID` and routes the hub side to the order book
    ///      directly; the pool stays on this network, so the message is delivered in place and the payment is refunded.
    function _setupRemoteAssetPool() internal {
        poolE = hubRegistry.poolId(CENTRIFUGE_ID, 5);
        scE = _createPool(poolE, address(fullRestrictions), false);
        shareE = IShareToken(address(spokeRegistry.shareToken(poolE, scE)));

        usdcE = new ERC20(USDC_DECIMALS);
        usdcEId = spokeRegistry.createAssetId(REMOTE_ID, address(usdcE), 0);
        hubRegistry.setHubRequestManager(poolE, REMOTE_ID, IHubRequestManager(address(orderBook)));

        bytes memory payload = abi.encode(_plugins(perRequestPolicy, false, address(0)), uint64(0), uint256(0));
        vaultE = IAsyncVault(vaultFactory.deploy(poolE, scE, address(usdcE), 0, payload));
        spokeHandler.updateVault(poolE, scE, usdcEId, address(vaultFactory), VaultUpdateKind.DeployAndLink, payload);
        require(spokeRegistry.isLinked(address(vaultE)), "vault E not linked");
        _updateManager(poolE, address(vaultE), true);
        for (uint256 i; i < actors.length; i++) {
            usdcE.mint(actors[i], ACTOR_FUNDS);
            _updateRestriction(poolE, scE, _memberMsg(actors[i]));
        }
    }

    /// @dev Flushes a pool's asset and share queues to the hub as one of its vaults, a spoke manager of the pool.
    function _submitQueues(PoolId poolId, ShareClassId scId, address manager) internal {
        vm.prank(manager);
        spoke.submitQueuedAssets(poolId, scId, usdcId, 0, REFUND);
        vm.prank(manager);
        spoke.submitQueuedShares(poolId, scId, 0, REFUND);
    }

    function _fulfillD(uint256 requestId, uint128 amount) internal {
        _fm();
        feeRequestManager.fulfill(poolD, scD, usdcId, RequestId.wrap(requestId), true, amount, 0, REFUND);
    }

    /// @dev Replaces FM as the pool's hub manager, and withdraws the BSM's spoke role and the FEEDER's price role,
    ///      so nobody who acts on pool A holds a role on `poolId`. `spokeToo` also makes the new manager a spoke manager (the balance-sheet
    ///      calls of an adversary).
    function _handOver(PoolId poolId, address manager, bool spokeToo) internal {
        _updateManager(poolId, BSM, false);
        _managerCall(poolId, address(oracleValuation), abi.encode(uint16(0), FEEDER.toBytes32(), false));
        if (spokeToo) _updateManager(poolId, manager, true);
        _fm();
        hub.updateHubManager(poolId, manager, true);
        _fm();
        hub.updateHubManager(poolId, FM, false);
    }

    function _footprintA() internal view returns (bytes32) {
        address[] memory vs = new address[](vaults.length);
        for (uint256 i; i < vs.length; i++) {
            vs[i] = address(vaults[i]);
        }
        return _footprint(poolA, scA, shareA, vs, actors[0]);
    }

    function _footprintB() internal view returns (bytes32) {
        return _footprint(poolB, scB, shareB, _one(address(vaultB)), INVESTOR_B);
    }

    function _footprintC() internal view returns (bytes32) {
        return _footprint(poolC, scC, shareC, _one(address(vaultC)), actors[0]);
    }

    function _footprintD() internal view returns (bytes32) {
        return _footprint(poolD, scD, shareD, _one(address(vaultD)), INVESTOR_D);
    }

    function _one(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }

    /// @dev Everything a stray write could land in for one pool, as a hash of a fixed set of reads: the pool's
    ///      share queues and nonce, accounts, prices on both sides, hub and spoke manager roles, request manager,
    ///      share class, holding, escrow balances and reservations, supply, a holder's position, and for each of
    ///      its vaults the registry link, the policy, route and consent state the singletons keep under it, the
    ///      request manager's orders and the vault's buckets. The reads are raw static calls, so a getter that
    ///      reverts is part of the hash instead of hiding the change behind a revert.
    function _footprint(PoolId poolId, ShareClassId scId, IShareToken share, address[] memory vs, address holder)
        internal
        view
        returns (bytes32 acc)
    {
        IEscrow escrow = _escrow(poolId);
        acc = _read(acc, address(snapshotQueue), abi.encodeCall(snapshotQueue.queuedShares, (poolId, scId)));
        acc = _read(acc, address(snapshotQueue), abi.encodeCall(snapshotQueue.queuedAssets, (poolId, scId, usdcId)));
        AccountId[4] memory accts = _accounts();
        for (uint256 i; i < 4; i++) {
            acc = _read(acc, address(accounting), abi.encodeCall(accounting.accounts, (poolId, accts[i])));
        }
        acc = _read(acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.pool, (poolId)));
        acc = _read(acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.requestManager, (poolId)));
        acc = _read(acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.shareClass, (poolId, scId)));
        acc = _read(acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.policy, (poolId)));
        acc = _read(acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.pricePoolPerShare, (poolId, scId, false)));
        acc = _read(
            acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.pricePoolPerShareComputedAt, (poolId, scId))
        );
        acc = _read(
            acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.pricePoolPerAsset, (poolId, scId, usdcId, false))
        );
        acc = _read(
            acc,
            address(spokeRegistry),
            abi.encodeCall(spokeRegistry.pricePoolPerAssetComputedAt, (poolId, scId, usdcId))
        );
        acc = _read(acc, address(hubRegistry), abi.encodeCall(hubRegistry.policy, (poolId)));
        acc =
            _read(acc, address(shareClassManager), abi.encodeCall(shareClassManager.pricePoolPerShare, (poolId, scId)));
        acc = _read(
            acc, address(shareClassManager), abi.encodeCall(shareClassManager.issuanceAcrossNetworks, (poolId, scId))
        );
        acc = _read(
            acc, address(shareClassManager), abi.encodeCall(shareClassManager.issuance, (poolId, scId, CENTRIFUGE_ID))
        );
        acc = _read(acc, address(shareClassManager), abi.encodeCall(shareClassManager.shareClassCount, (poolId)));
        acc = _read(acc, address(holdings), abi.encodeCall(holdings.amount, (poolId, scId, usdcId)));
        acc = _read(acc, address(holdings), abi.encodeCall(holdings.value, (poolId, scId, usdcId)));
        acc = _read(acc, address(holdings), abi.encodeCall(holdings.valuation, (poolId, scId, usdcId)));
        acc = _read(acc, address(holdings), abi.encodeCall(holdings.isInitialized, (poolId, scId, usdcId)));
        acc = _read(acc, address(escrow), abi.encodeCall(escrow.holding, (scId, address(usdc), 0)));
        acc = _read(acc, address(usdc), abi.encodeCall(usdc.balanceOf, (address(escrow))));
        acc = _read(acc, address(share), abi.encodeCall(share.balanceOf, (address(escrow))));
        acc = _read(acc, address(share), abi.encodeCall(share.totalSupply, ()));
        acc = _read(acc, address(share), abi.encodeCall(share.balanceOf, (holder)));
        acc = _read(acc, address(usdc), abi.encodeCall(usdc.balanceOf, (holder)));
        acc = _read(acc, address(share), abi.encodeCall(share.hook, ()));
        acc = _read(acc, address(share), abi.encodeWithSignature("vault(address)", address(usdc)));
        acc = _read(acc, address(orderBook), abi.encodeCall(orderBook.observer, (poolId)));
        acc = _read(acc, address(feeRequestManager), abi.encodeCall(feeRequestManager.feeBps, (poolId, usdcId)));
        acc = _read(acc, address(spokeOracle), abi.encodeCall(spokeOracle.isPaused, (poolId)));
        acc = _read(acc, address(fullRestrictions), abi.encodeCall(fullRestrictions.isMember, (address(share), holder)));

        address[9] memory principals = [
            FM,
            BSM,
            AUX_MANAGER,
            MALLORY,
            MANAGER_B,
            address(vaultRoute),
            address(basinRoute),
            address(vaultRouter),
            holder
        ];
        for (uint256 i; i < principals.length; i++) {
            acc = _read(acc, address(hubRegistry), abi.encodeCall(hubRegistry.manager, (poolId, principals[i])));
            acc = _read(acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.manager, (poolId, principals[i])));
            acc = _read(
                acc,
                address(fullRestrictions),
                abi.encodeCall(fullRestrictions.manager, (address(share), principals[i]))
            );
            acc = _read(acc, address(share), abi.encodeWithSignature("wards(address)", principals[i]));
        }
        for (uint256 v; v < vs.length; v++) {
            acc = _vaultFootprint(acc, poolId, scId, vs[v], holder, principals);
        }
    }

    function _vaultFootprint(
        bytes32 acc,
        PoolId poolId,
        ShareClassId scId,
        address vault,
        address holder,
        address[9] memory principals
    ) internal view returns (bytes32) {
        IAsyncVault v = IAsyncVault(vault);
        acc = _read(acc, address(spokeRegistry), abi.encodeCall(spokeRegistry.vaultDetails, (vault)));
        acc = _read(acc, address(reserveInstantPolicy), abi.encodeCall(reserveInstantPolicy.config, (vault)));
        acc = _read(acc, address(vaultRoute), abi.encodeCall(vaultRoute.routes, (vault)));
        acc = _read(acc, address(basinRoute), abi.encodeCall(basinRoute.limit, (vault)));
        acc = _read(acc, address(basinRoute), abi.encodeCall(basinRoute.credit, (vault)));
        acc = _read(acc, address(basinRoute), abi.encodeCall(basinRoute.receivable, (vault)));
        acc = _read(acc, address(v), abi.encodeCall(v.pendingDepositRequest, (0, holder)));
        acc = _read(acc, address(v), abi.encodeCall(v.pendingRedeemRequest, (0, holder)));
        acc = _read(acc, address(v), abi.encodeCall(v.claimableMint, (holder)));
        acc = _read(acc, address(v), abi.encodeCall(v.claimableWithdraw, (holder)));
        for (uint256 i; i < principals.length; i++) {
            for (
                uint8 k = uint8(IReserveInstantPolicy.ConfigKind.Depositor);
                k <= uint8(IReserveInstantPolicy.ConfigKind.Sponsor);
                k++
            ) {
                acc = _read(
                    acc,
                    address(reserveInstantPolicy),
                    abi.encodeCall(
                        reserveInstantPolicy.isAllowed, (vault, IReserveInstantPolicy.ConfigKind(k), principals[i])
                    )
                );
            }
            acc = _read(acc, address(vaultRoute), abi.encodeCall(vaultRoute.isConsented, (vault, principals[i])));
        }
        acc = _read(acc, address(vaultRoute), abi.encodeCall(vaultRoute.isConsented, (vault, address(vaultD))));
        acc = _read(acc, address(vaultRoute), abi.encodeCall(vaultRoute.isConsented, (vault, address(vaultB))));
        for (uint96 id; id < 4; id++) {
            RequestId rid = VaultRequestIdLib.from(vault, id);
            acc = _read(acc, address(v), abi.encodeCall(v.bucket, (id)));
            acc = _read(acc, address(orderBook), abi.encodeCall(orderBook.depositOrders, (poolId, scId, usdcId, rid)));
            acc = _read(acc, address(orderBook), abi.encodeCall(orderBook.redeemOrders, (poolId, scId, usdcId, rid)));
        }
        return acc;
    }

    function _read(bytes32 acc, address target, bytes memory data) internal view returns (bytes32) {
        (bool success, bytes memory ret) = target.staticcall(data);
        return keccak256(abi.encode(acc, success, ret));
    }

    receive() external payable {}
}
