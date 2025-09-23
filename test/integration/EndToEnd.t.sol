// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {VMLabeling} from "./utils/VMLabeling.sol";
import {LocalAdapter} from "./adapters/LocalAdapter.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {D18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../src/misc/libraries/MathLib.sol";
import {ETH_ADDRESS} from "../../src/misc/interfaces/IRecoverable.sol";

import {Root} from "../../src/common/Root.sol";
import {Gateway} from "../../src/common/Gateway.sol";
import {Guardian} from "../../src/common/Guardian.sol";
import {PoolId} from "../../src/common/types/PoolId.sol";
import {GasService} from "../../src/common/GasService.sol";
import {AccountId} from "../../src/common/types/AccountId.sol";
import {ISafe} from "../../src/common/interfaces/IGuardian.sol";
import {IAdapter} from "../../src/common/interfaces/IAdapter.sol";
import {PricingLib} from "../../src/common/libraries/PricingLib.sol";
import {ShareClassId} from "../../src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/common/types/AssetId.sol";
import {IMessageHandler} from "../../src/common/interfaces/IMessageHandler.sol";
import {MultiAdapter, MAX_ADAPTER_COUNT} from "../../src/common/MultiAdapter.sol";
import {ILocalCentrifugeId} from "../../src/common/interfaces/IGatewaySenders.sol";
import {VaultUpdateKind, MessageType, MessageLib} from "../../src/common/libraries/MessageLib.sol";

import {Hub} from "../../src/hub/Hub.sol";
import {Holdings} from "../../src/hub/Holdings.sol";
import {Accounting} from "../../src/hub/Accounting.sol";
import {HubHelpers} from "../../src/hub/HubHelpers.sol";
import {HubRegistry} from "../../src/hub/HubRegistry.sol";
import {ShareClassManager} from "../../src/hub/ShareClassManager.sol";
import {IHubRequestManager} from "../../src/hub/interfaces/IHubRequestManager.sol";

import {Spoke} from "../../src/spoke/Spoke.sol";
import {IVault} from "../../src/spoke/interfaces/IVault.sol";
import {BalanceSheet} from "../../src/spoke/BalanceSheet.sol";
import {UpdateContractMessageLib} from "../../src/spoke/libraries/UpdateContractMessageLib.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {AsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../src/vaults/BatchRequestManager.sol";
import {IAsyncRedeemVault} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {IBatchRequestManager} from "../../src/vaults/interfaces/IBatchRequestManager.sol";

import {MockSnapshotHook} from "../hooks/mocks/MockSnapshotHook.sol";

import {FreezeOnly} from "../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "../../src/hooks/RedemptionRestrictions.sol";
import {UpdateRestrictionMessageLib} from "../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OracleValuation} from "../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../src/valuations/IdentityValuation.sol";

import {FullDeployer, FullActionBatcher, CommonInput} from "../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {RecoveryAdapter} from "../../src/adapters/RecoveryAdapter.sol";

import {MessageBenchmarker} from "./utils/MessageBenchmarker.sol";

/// End to end testing assuming two full deployments in two different chains
///
/// This EndToEnd tests emulates two chains fully deployed and connected through an adapter
/// Each test case can receive a fuzzed boolean parameter to be tested in both cases:
/// - If sameChain: HUB is in CENTRIFUGE_ID_A and CV is in CENTRIFUGE_ID_A
/// - If !sameChain: HUB is in CENTRIFUGE_ID_A and CV is in CENTRIFUGE_ID_B
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
        // Common
        Root root;
        Guardian guardian;
        Gateway gateway;
        MultiAdapter multiAdapter;
        GasService gasService;
        // Hub
        HubRegistry hubRegistry;
        Accounting accounting;
        Holdings holdings;
        ShareClassManager shareClassManager;
        Hub hub;
        HubHelpers hubHelpers;
        BatchRequestManager batchRequestManager;
        // Others
        IdentityValuation identityValuation;
        OracleValuation oracleValuation;
        MockSnapshotHook snapshotHook;
    }

    struct CSpoke {
        uint16 centrifugeId;
        // Common
        Root root;
        Guardian guardian;
        Gateway gateway;
        MultiAdapter multiAdapter;
        // Vaults
        BalanceSheet balanceSheet;
        Spoke spoke;
        VaultRouter router;
        bytes32 asyncVaultFactory;
        bytes32 syncDepositVaultFactory;
        AsyncRequestManager asyncRequestManager;
        SyncManager syncManager;
        // Hooks
        FreezeOnly freezeOnlyHook;
        FullRestrictions fullRestrictionsHook;
        RedemptionRestrictions redemptionRestrictionsHook;
        // Others
        ERC20 usdc;
        AssetId usdcId;
    }

    ISafe immutable SAFE_ADMIN_A = ISafe(makeAddr("SafeAdminA"));
    ISafe immutable SAFE_ADMIN_B = ISafe(makeAddr("SafeAdminB"));

    uint16 constant CENTRIFUGE_ID_A = IntegrationConstants.CENTRIFUGE_ID_A;
    uint16 constant CENTRIFUGE_ID_B = IntegrationConstants.CENTRIFUGE_ID_B;
    uint128 constant GAS = IntegrationConstants.GAS;
    uint256 constant DEFAULT_SUBSIDY = IntegrationConstants.DEFAULT_SUBSIDY;
    uint128 constant HOOK_GAS = IntegrationConstants.HOOK_GAS;

    address immutable ERC20_DEPLOYER = address(this);
    address immutable FM = makeAddr("FM");
    address immutable BSM = makeAddr("BSM");
    address immutable FEEDER = makeAddr("FEEDER");
    address immutable INVESTOR_A = makeAddr("INVESTOR_A");
    address immutable ANY = makeAddr("ANY");
    address immutable GATEWAY_MANAGER = makeAddr("GATEWAY_MANAGER");

    uint128 constant USDC_AMOUNT_1 = IntegrationConstants.DEFAULT_USDC_AMOUNT;

    AccountId constant ASSET_ACCOUNT = IntegrationConstants.ASSET_ACCOUNT;
    AccountId constant EQUITY_ACCOUNT = IntegrationConstants.EQUITY_ACCOUNT;
    AccountId constant LOSS_ACCOUNT = IntegrationConstants.LOSS_ACCOUNT;
    AccountId constant GAIN_ACCOUNT = IntegrationConstants.GAIN_ACCOUNT;

    PoolId constant GLOBAL_POOL = PoolId.wrap(0);

    AssetId USD_ID;
    PoolId POOL_A;
    ShareClassId SC_1;

    FullDeployer deployA = new FullDeployer();
    FullDeployer deployB = new FullDeployer();

    LocalAdapter adapterAToB;
    LocalAdapter adapterBToA;

    LocalAdapter poolAdapterAToB = new LocalAdapter(h.centrifugeId, h.multiAdapter, FM);
    LocalAdapter poolAdapterBToA = new LocalAdapter(s.centrifugeId, s.multiAdapter, FM);

    CHub h;
    CSpoke s;

    uint8 constant USDC_DECIMALS = IntegrationConstants.USDC_DECIMALS;
    uint8 constant POOL_DECIMALS = IntegrationConstants.POOL_DECIMALS;
    uint8 constant SHARE_DECIMALS = POOL_DECIMALS;

    uint256 constant PLACEHOLDER_REQUEST_ID = IntegrationConstants.PLACEHOLDER_REQUEST_ID;
    uint128 constant EXTRA_GAS = IntegrationConstants.EXTRA_GAS;

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

        h = CHub({
            centrifugeId: CENTRIFUGE_ID_A,
            root: deployA.root(),
            guardian: deployA.guardian(),
            gateway: deployA.gateway(),
            multiAdapter: deployA.multiAdapter(),
            gasService: deployA.gasService(),
            hubRegistry: deployA.hubRegistry(),
            accounting: deployA.accounting(),
            holdings: deployA.holdings(),
            shareClassManager: deployA.shareClassManager(),
            hub: deployA.hub(),
            hubHelpers: deployA.hubHelpers(),
            batchRequestManager: deployA.batchRequestManager(),
            identityValuation: deployA.identityValuation(),
            oracleValuation: deployA.oracleValuation(),
            snapshotHook: new MockSnapshotHook()
        });

        // Initialize default values
        USD_ID = deployA.USD_ID();
        POOL_A = h.hubRegistry.poolId(CENTRIFUGE_ID_A, 1);
        SC_1 = h.shareClassManager.previewNextShareClassId(POOL_A);

        h.gateway.depositSubsidy{value: DEFAULT_SUBSIDY}(GLOBAL_POOL);

        vm.label(address(adapterAToB), "AdapterAToB");
        vm.label(address(adapterBToA), "AdapterBToA");
    }

    function _setAdapter(FullDeployer deploy, uint16 remoteCentrifugeId, IAdapter adapter) internal {
        vm.startPrank(address(deploy.guardian().safe()));
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = adapter;
        deploy.guardian().setAdapters(remoteCentrifugeId, adapters, uint8(adapters.length), uint8(adapters.length));
        deploy.guardian().updateGatewayManager(GATEWAY_MANAGER, true);
        vm.stopPrank();
    }

    function _deployChain(FullDeployer deploy, uint16 localCentrifugeId, uint16 remoteCentrifugeId, ISafe adminSafe)
        internal
        returns (LocalAdapter adapter)
    {
        CommonInput memory commonInput = CommonInput({
            centrifugeId: localCentrifugeId,
            adminSafe: adminSafe,
            maxBatchGasLimit: uint128(GAS) * 100,
            version: bytes32(abi.encodePacked(localCentrifugeId))
        });

        FullActionBatcher batcher = new FullActionBatcher();
        batcher.setDeployer(address(deploy));

        deploy.labelAddresses(string(abi.encodePacked(localCentrifugeId, "-")));
        deploy.deployFull(commonInput, deploy.noAdaptersInput(), batcher);

        adapter = new LocalAdapter(localCentrifugeId, deploy.multiAdapter(), address(deploy));
        _setAdapter(deploy, remoteCentrifugeId, adapter);

        // Only run the benchmarks if using one thread to avoid concurrence issues writting the json
        // Example of command: RAYON_NUM_THREADS=1 RUN_ID="$(date +%s)" forge test EndToEnd
        if (vm.envOr("RAYON_NUM_THREADS", uint256(0)) == 1) {
            _attachBenchmark(deploy, batcher);
        }

        deploy.removeFullDeployerAccess(batcher);
    }

    function _attachBenchmark(FullDeployer deploy, FullActionBatcher batcher) internal {
        vm.startPrank(address(batcher));
        MessageBenchmarker benchmarker = new MessageBenchmarker(deploy.messageProcessor());
        deploy.messageProcessor().rely(address(benchmarker));
        deploy.gateway().file("processor", address(benchmarker));
        vm.stopPrank();
    }

    function _setSpoke(FullDeployer deploy, uint16 centrifugeId, CSpoke storage s_) internal {
        if (s_.centrifugeId != 0) return; // Already set

        s_.centrifugeId = centrifugeId;
        s_.root = deploy.root();
        s_.guardian = deploy.guardian();
        s_.gateway = deploy.gateway();
        s_.multiAdapter = deploy.multiAdapter();
        s_.balanceSheet = deploy.balanceSheet();
        s_.spoke = deploy.spoke();
        s_.router = deploy.vaultRouter();
        s_.freezeOnlyHook = deploy.freezeOnlyHook();
        s_.fullRestrictionsHook = deploy.fullRestrictionsHook();
        s_.redemptionRestrictionsHook = deploy.redemptionRestrictionsHook();
        s_.asyncVaultFactory = address(deploy.asyncVaultFactory()).toBytes32();
        s_.syncDepositVaultFactory = address(deploy.syncDepositVaultFactory()).toBytes32();
        s_.asyncRequestManager = deploy.asyncRequestManager();
        s_.syncManager = deploy.syncManager();
        s_.usdc = new ERC20(6);
        s_.usdcId = newAssetId(centrifugeId, 1);

        // Initialize default values
        s_.usdc.file("name", "USD Coin");
        s_.usdc.file("symbol", "USDC");

        s_.gateway.depositSubsidy{value: DEFAULT_SUBSIDY}(GLOBAL_POOL);
    }

    function _setSpoke(bool sameChain) internal {
        if (sameChain) {
            _setSpoke(deployA, CENTRIFUGE_ID_A, s);
        } else {
            _setSpoke(deployB, CENTRIFUGE_ID_B, s);
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

    function _getAsyncVault(CSpoke memory spoke, PoolId poolId, ShareClassId shareClassId, AssetId assetId)
        internal
        view
        returns (address vaultAddr)
    {
        return address(spoke.spoke.vault(poolId, shareClassId, assetId, spoke.asyncRequestManager));
    }

    function _getOrCreateAsyncVault(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager
    ) internal returns (address vaultAddr) {
        vaultAddr = address(spoke.spoke.vault(poolId, shareClassId, assetId, spoke.asyncRequestManager));
        if (vaultAddr == address(0)) {
            vm.startPrank(poolManager);
            hub.hub.updateVault(
                poolId, shareClassId, assetId, spoke.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS
            );
            vm.stopPrank();
            vaultAddr = address(spoke.spoke.vault(poolId, shareClassId, assetId, spoke.asyncRequestManager));
        }
        assertNotEq(vaultAddr, address(0));
    }
}

/// Base investment flows that can be shared between EndToEnd tests
contract EndToEndFlows is EndToEndUtils {
    using CastLib for *;
    using UpdateContractMessageLib for *;
    using UpdateRestrictionMessageLib for *;
    using MathLib for *;

    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
            user: addr.toBytes32(),
            validUntil: type(uint64).max
        }).serialize();
    }

    function _updateContractSyncDepositMaxReserveMsg(AssetId assetId, uint128 maxReserve)
        internal
        pure
        returns (bytes memory)
    {
        return UpdateContractMessageLib.UpdateContractSyncDepositMaxReserve({
            assetId: assetId.raw(),
            maxReserve: maxReserve
        }).serialize();
    }

    //----------------------------------------------------------------------------------------------
    // Asset & Pool Configuration
    //----------------------------------------------------------------------------------------------

    function _configureAsset(CSpoke memory s_) internal {
        vm.startPrank(ERC20_DEPLOYER);
        s_.usdc.mint(INVESTOR_A, USDC_AMOUNT_1);

        vm.startPrank(ANY);
        s_.spoke.registerAsset{value: GAS}(h.centrifugeId, address(s_.usdc), 0);
    }

    function _createPoolAccounts(CHub memory hub, PoolId poolId, address poolManager) internal {
        vm.startPrank(poolManager);
        hub.hub.createAccount(poolId, ASSET_ACCOUNT, true);
        hub.hub.createAccount(poolId, EQUITY_ACCOUNT, false);
        hub.hub.createAccount(poolId, LOSS_ACCOUNT, false);
        hub.hub.createAccount(poolId, GAIN_ACCOUNT, false);
        vm.stopPrank();
    }

    function _createPool() internal {
        vm.startPrank(address(h.guardian.safe()));
        h.guardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32("salt"));

        _createPoolAccounts(h, POOL_A, FM);
        h.gateway.depositSubsidy{value: DEFAULT_SUBSIDY}(POOL_A);
    }

    function _configurePoolCrossChain(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address hookAddress
    ) internal {
        vm.startPrank(poolManager);
        vm.deal(poolManager, 1 ether);

        hub.hub.notifyPool(poolId, spoke.centrifugeId);
        hub.hub.notifyShareClass(poolId, shareClassId, spoke.centrifugeId, hookAddress.toBytes32());

        hub.hub.initializeHolding(
            poolId,
            shareClassId,
            assetId,
            hub.oracleValuation,
            ASSET_ACCOUNT,
            EQUITY_ACCOUNT,
            GAIN_ACCOUNT,
            LOSS_ACCOUNT
        );
        hub.hub.setRequestManager(
            poolId,
            spoke.centrifugeId,
            IHubRequestManager(hub.batchRequestManager),
            address(spoke.asyncRequestManager).toBytes32()
        );
        hub.hub.updateBalanceSheetManager(
            spoke.centrifugeId, poolId, address(spoke.asyncRequestManager).toBytes32(), true
        );
        hub.hub.updateBalanceSheetManager(spoke.centrifugeId, poolId, address(spoke.syncManager).toBytes32(), true);
        hub.hub.updateBalanceSheetManager(spoke.centrifugeId, poolId, BSM.toBytes32(), true);

        vm.stopPrank();
    }

    function _configurePool(CSpoke memory s_) internal {
        _configureAsset(s_);

        if (!h.hubRegistry.exists(POOL_A)) {
            _createPool();
        }

        _configurePoolCrossChain(h, s_, POOL_A, SC_1, s_.usdcId, FM, address(s_.redemptionRestrictionsHook));

        vm.startPrank(FM);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);
        h.oracleValuation.updateFeeder(POOL_A, FEEDER, true);
        h.hub.updateHubManager(POOL_A, address(h.oracleValuation), true);
        h.hub.updateGatewayManager(h.centrifugeId, POOL_A, address(h.batchRequestManager).toBytes32(), true);
        vm.stopPrank();

        // We also subsidize the hub
        if (s.centrifugeId != h.centrifugeId) {
            vm.startPrank(ANY);
            s_.gateway.depositSubsidy{value: DEFAULT_SUBSIDY}(POOL_A);
        }
    }

    function _configurePool(bool sameChain) internal {
        _setSpoke(sameChain);
        _configurePool(s);
    }

    function _configureBasePoolWithCustomAdapters() internal {
        _setSpoke(IN_DIFFERENT_CHAINS);
        _createPool();

        // Wire pool adapters
        poolAdapterAToB = new LocalAdapter(h.centrifugeId, h.multiAdapter, FM);
        poolAdapterBToA = new LocalAdapter(s.centrifugeId, s.multiAdapter, FM);

        poolAdapterAToB.setEndpoint(poolAdapterBToA);
        poolAdapterBToA.setEndpoint(poolAdapterAToB);

        IAdapter[] memory localAdapters = new IAdapter[](1);
        localAdapters[0] = poolAdapterAToB;

        bytes32[] memory remoteAdapters = new bytes32[](1);
        remoteAdapters[0] = address(poolAdapterBToA).toBytes32();

        vm.startPrank(FM);
        h.hub.setAdapters(s.centrifugeId, POOL_A, localAdapters, remoteAdapters, 1, 1);
        h.hub.updateGatewayManager(h.centrifugeId, POOL_A, GATEWAY_MANAGER.toBytes32(), true);
        h.hub.updateGatewayManager(s.centrifugeId, POOL_A, GATEWAY_MANAGER.toBytes32(), true);
    }

    //----------------------------------------------------------------------------------------------
    // Price Management
    //----------------------------------------------------------------------------------------------

    function _baseConfigurePrices(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        D18 assetPrice,
        D18 sharePrice
    ) internal virtual {
        vm.startPrank(FEEDER);
        hub.oracleValuation.setPrice(poolId, shareClassId, assetId, assetPrice);
        vm.stopPrank();

        vm.startPrank(poolManager);
        hub.hub.updateSharePrice(poolId, shareClassId, sharePrice);
        hub.hub.notifySharePrice(poolId, shareClassId, spoke.centrifugeId);
        hub.hub.notifyAssetPrice(poolId, shareClassId, assetId);

        currentAssetPrice = assetPrice;
        currentSharePrice = sharePrice;
    }

    function _configurePrices(D18 assetPrice, D18 sharePrice) internal {
        _baseConfigurePrices(h, s, POOL_A, SC_1, s.usdcId, FM, assetPrice, sharePrice);
    }

    //----------------------------------------------------------------------------------------------
    // Async Deposit Flows
    //----------------------------------------------------------------------------------------------

    function _asyncDepositFlow(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address investor,
        uint128 amount,
        bool nonZeroPrices
    ) internal {
        // Configure prices
        _configurePricesForFlow(hub, spoke, poolId, shareClassId, assetId, poolManager, nonZeroPrices);

        // Deploy or get existing vault
        IAsyncVault vault = IAsyncVault(_getOrCreateAsyncVault(hub, spoke, poolId, shareClassId, assetId, poolManager));

        // Execute deposit request
        _executeAsyncDepositRequest(vault, investor, amount);

        // Process deposit approval and share issuance
        _processAsyncDepositApproval(hub, poolId, shareClassId, assetId, poolManager, amount);

        // Claim shares
        _processAsyncDepositClaim(hub, spoke, poolId, shareClassId, assetId, investor, vault, amount);
    }

    function _configurePricesForFlow(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        bool nonZeroPrices
    ) internal {
        _baseConfigurePrices(
            hub,
            spoke,
            poolId,
            shareClassId,
            assetId,
            poolManager,
            nonZeroPrices ? IntegrationConstants.assetPrice() : IntegrationConstants.zeroPrice(),
            nonZeroPrices ? IntegrationConstants.sharePrice() : IntegrationConstants.zeroPrice()
        );
    }

    function _executeAsyncDepositRequest(IAsyncVault vault, address investor, uint128 amount) internal {
        vm.startPrank(investor);
        ERC20(vault.asset()).approve(address(vault), amount);
        vault.requestDeposit(amount, investor, investor);
    }

    function _processAsyncDepositApproval(
        CHub memory hub,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        uint128 amount
    ) internal {
        vm.startPrank(poolManager);
        uint32 depositEpochId = hub.batchRequestManager.nowDepositEpoch(shareClassId, assetId);
        D18 pricePoolPerAsset = hub.hubHelpers.pricePoolPerAsset(poolId, shareClassId, assetId);
        hub.hub.callRequestManager(
            poolId,
            assetId.centrifugeId(),
            abi.encodeCall(
                IBatchRequestManager.approveDeposits,
                (poolId, shareClassId, assetId, depositEpochId, amount, pricePoolPerAsset)
            )
        );

        vm.startPrank(poolManager);
        uint32 issueEpochId = hub.batchRequestManager.nowIssueEpoch(shareClassId, assetId);
        (, D18 sharePrice) = hub.shareClassManager.metrics(shareClassId);
        hub.hub.callRequestManager(
            poolId,
            assetId.centrifugeId(),
            abi.encodeCall(
                IBatchRequestManager.issueShares, (poolId, shareClassId, assetId, issueEpochId, sharePrice, HOOK_GAS)
            )
        );
    }

    function _processAsyncDepositClaim(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address investor,
        IAsyncVault vault,
        uint128 amount
    ) internal {
        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        hub.batchRequestManager.notifyDeposit{value: GAS}(
            poolId,
            shareClassId,
            assetId,
            investor.toBytes32(),
            hub.batchRequestManager.maxDepositClaims(shareClassId, investor.toBytes32(), assetId)
        );

        vm.startPrank(investor);
        vault.mint(vault.maxMint(investor), investor);

        // CHECKS
        assertEq(
            spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor), assetToShare(amount), "expected shares"
        );
    }

    function _testAsyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _configurePool(sameChain);
        _asyncDepositFlow(h, s, POOL_A, SC_1, s.usdcId, FM, INVESTOR_A, USDC_AMOUNT_1, nonZeroPrices);
    }

    //----------------------------------------------------------------------------------------------
    // Sync Deposit Flows
    //----------------------------------------------------------------------------------------------

    function _syncDepositFlow(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address investor,
        uint128 amount,
        bool nonZeroPrices
    ) internal {
        _configurePricesForFlow(hub, spoke, poolId, shareClassId, assetId, poolManager, nonZeroPrices);
        _configureSyncDepositVault(hub, spoke, poolId, shareClassId, assetId, poolManager);
        _processSyncDeposit(hub, spoke, poolId, shareClassId, assetId, investor, amount);
    }

    function _configureSyncDepositVault(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager
    ) internal {
        vm.startPrank(poolManager);
        // Check if vault already exists (for live tests)
        address existingVault = _getAsyncVault(spoke, poolId, shareClassId, assetId);
        if (existingVault == address(0)) {
            hub.hub.updateVault(
                poolId, shareClassId, assetId, spoke.syncDepositVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS
            );
        }
        hub.hub.updateContract(
            poolId,
            shareClassId,
            spoke.centrifugeId,
            address(spoke.syncManager).toBytes32(),
            _updateContractSyncDepositMaxReserveMsg(assetId, type(uint128).max),
            EXTRA_GAS
        );
    }

    function _processSyncDeposit(
        CHub memory,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address investor,
        uint128 amount
    ) internal {
        IBaseVault vault = IBaseVault(_getAsyncVault(spoke, poolId, shareClassId, assetId));

        vm.startPrank(investor);
        spoke.usdc.approve(address(vault), amount);
        vault.deposit(amount, investor);

        assertEq(
            spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor), assetToShare(amount), "expected shares"
        );
    }

    function _testSyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _configurePool(sameChain);
        _syncDepositFlow(h, s, POOL_A, SC_1, s.usdcId, FM, INVESTOR_A, USDC_AMOUNT_1, nonZeroPrices);
    }

    //----------------------------------------------------------------------------------------------
    // Async Redeem Flows
    //----------------------------------------------------------------------------------------------

    function _asyncRedeemFlow(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address poolManager,
        address investor,
        bool nonZeroPrices
    ) internal {
        // Configure prices using unified helper
        _configurePricesForFlow(hub, spoke, poolId, shareClassId, assetId, poolManager, nonZeroPrices);

        _configureAsyncRedeemRestriction(hub, spoke, poolId, shareClassId, investor, poolManager);

        // Get vault from manager
        IAsyncRedeemVault vault = IAsyncRedeemVault(_getAsyncVault(spoke, poolId, shareClassId, assetId));

        vm.startPrank(investor);
        uint128 shares = uint128(spoke.spoke.shareToken(poolId, shareClassId).balanceOf(investor));

        vault.requestRedeem(shares, investor, investor);

        _processAsyncRedeemApproval(hub, poolId, shareClassId, assetId, shares, poolManager);
        _processAsyncRedeemClaim(hub, spoke, poolId, shareClassId, assetId, investor, vault, shares);
    }

    function _configureAsyncRedeemRestriction(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        address investor,
        address poolManager
    ) internal {
        vm.startPrank(poolManager);
        hub.hub.updateRestriction(
            poolId, shareClassId, spoke.centrifugeId, _updateRestrictionMemberMsg(investor), EXTRA_GAS
        );
    }

    function _processAsyncRedeemApproval(
        CHub memory hub,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        uint128 shares,
        address poolManager
    ) internal {
        vm.startPrank(poolManager);
        uint32 redeemEpochId = hub.batchRequestManager.nowRedeemEpoch(shareClassId, assetId);
        D18 pricePoolPerAsset = hub.hubHelpers.pricePoolPerAsset(poolId, shareClassId, assetId);
        hub.hub.callRequestManager(
            poolId,
            assetId.centrifugeId(),
            abi.encodeCall(
                IBatchRequestManager.approveRedeems,
                (poolId, shareClassId, assetId, redeemEpochId, shares, pricePoolPerAsset)
            )
        );

        uint32 revokeEpochId = hub.batchRequestManager.nowRevokeEpoch(shareClassId, assetId);
        (, D18 sharePrice) = hub.shareClassManager.metrics(shareClassId);
        hub.hub.callRequestManager(
            poolId,
            assetId.centrifugeId(),
            abi.encodeCall(
                IBatchRequestManager.revokeShares, (poolId, shareClassId, assetId, revokeEpochId, sharePrice, HOOK_GAS)
            )
        );
    }

    function _processAsyncRedeemClaim(
        CHub memory hub,
        CSpoke memory spoke,
        PoolId poolId,
        ShareClassId shareClassId,
        AssetId assetId,
        address investor,
        IAsyncRedeemVault vault,
        uint128 shares
    ) internal {
        vm.startPrank(ANY);
        vm.deal(ANY, GAS);
        hub.batchRequestManager.notifyRedeem{value: GAS}(
            poolId,
            shareClassId,
            assetId,
            investor.toBytes32(),
            hub.batchRequestManager.maxRedeemClaims(shareClassId, investor.toBytes32(), assetId)
        );

        vm.startPrank(investor);
        vault.withdraw(vault.maxWithdraw(investor), investor, investor);

        assertEq(spoke.usdc.balanceOf(investor), shareToAsset(shares), "expected assets");
    }

    function _testAsyncRedeem(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) internal {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, true) : _testSyncDeposit(sameChain, true);
        _asyncRedeemFlow(h, s, POOL_A, SC_1, s.usdcId, FM, INVESTOR_A, nonZeroPrices);
    }

    //----------------------------------------------------------------------------------------------
    // Test Cancellation & Edge Cases
    //----------------------------------------------------------------------------------------------

    function _testAsyncRedeemCancel(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) public {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, true) : _testSyncDeposit(sameChain, true);
        uint128 expectedShares = assetToShare(USDC_AMOUNT_1);

        nonZeroPrices
            ? _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice())
            : _configurePrices(IntegrationConstants.zeroPrice(), IntegrationConstants.zeroPrice());

        vm.startPrank(FM);
        h.hub.updateRestriction(POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS);

        IAsyncRedeemVault vault =
            IAsyncRedeemVault(address(s.spoke.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager)));

        vm.startPrank(INVESTOR_A);
        uint128 shares = uint128(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A));
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);
        vault.cancelRedeemRequest(PLACEHOLDER_REQUEST_ID, INVESTOR_A);
        vault.claimCancelRedeemRequest(PLACEHOLDER_REQUEST_ID, INVESTOR_A, INVESTOR_A);

        // CHECKS
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), expectedShares, "expected shares");
    }

    function _testUpdateAccountingAfterDeposit(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) public {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, nonZeroPrices) : _testSyncDeposit(sameChain, nonZeroPrices);

        vm.startPrank(BSM);
        s.balanceSheet.submitQueuedAssets(POOL_A, SC_1, s.usdcId, EXTRA_GAS);
        s.balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);

        // CHECKS
        (uint128 amount, uint128 value,,) = h.holdings.holding(POOL_A, SC_1, s.usdcId);
        assertEq(amount, USDC_AMOUNT_1, "expected amount");
        assertEq(value, assetToPool(USDC_AMOUNT_1), "expected value");

        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), nonZeroPrices ? 1 : 2, "expected snapshots");

        checkAccountValue(ASSET_ACCOUNT, assetToPool(USDC_AMOUNT_1), true);
        checkAccountValue(EQUITY_ACCOUNT, assetToPool(USDC_AMOUNT_1), true);
    }

    function _testUpdateAccountingAfterRedeem(bool sameChain, bool afterAsyncDeposit) public {
        _testAsyncRedeem(sameChain, afterAsyncDeposit, true);

        vm.startPrank(BSM);
        s.balanceSheet.submitQueuedAssets(POOL_A, SC_1, s.usdcId, EXTRA_GAS);
        s.balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);

        (uint128 amount, uint128 value,,) = h.holdings.holding(POOL_A, SC_1, s.usdcId);
        assertEq(amount, 0, "expected amount");
        assertEq(value, assetToPool(0), "expected value");

        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), 2, "expected snapshots");

        checkAccountValue(ASSET_ACCOUNT, assetToPool(0), true);
        checkAccountValue(EQUITY_ACCOUNT, assetToPool(0), true);
    }
}

/// Common and generic flows ready to be used in different tests
contract EndToEndUseCases is EndToEndFlows, VMLabeling {
    using CastLib for *;
    using MathLib for *;
    using MessageLib for *;

    function setUp() public virtual override {
        super.setUp();
        _setupVMLabels();
    }

    /// forge-config: default.isolate = true
    function testWardUpgrade(bool sameChain) public {
        address NEW_WARD = makeAddr("NewWard");

        _setSpoke(sameChain);

        vm.startPrank(address(SAFE_ADMIN_A));
        h.guardian.scheduleUpgrade(s.centrifugeId, NEW_WARD);
        h.guardian.cancelUpgrade(s.centrifugeId, NEW_WARD);
        h.guardian.scheduleUpgrade(s.centrifugeId, NEW_WARD);

        vm.warp(block.timestamp + deployA.DELAY() + 1000);

        vm.startPrank(ANY);
        s.root.executeScheduledRely(NEW_WARD);
    }

    /// forge-config: default.isolate = true
    function testTokenRecover(bool sameChain) public {
        address RECEIVER = makeAddr("Receiver");
        uint256 VALUE = 123;

        _setSpoke(sameChain);

        vm.startPrank(address(SAFE_ADMIN_A));
        h.guardian.recoverTokens(s.centrifugeId, address(s.gateway), ETH_ADDRESS, 0, RECEIVER, VALUE);

        assertEq(RECEIVER.balance, VALUE);
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
        h.hub.notifyShareMetadata(POOL_A, SC_1, s.centrifugeId);
        h.hub.updateShareHook(POOL_A, SC_1, s.centrifugeId, address(s.fullRestrictionsHook).toBytes32());

        assertEq(s.spoke.shareToken(POOL_A, SC_1).name(), "Tokenized MMF 2");
        assertEq(s.spoke.shareToken(POOL_A, SC_1).symbol(), "MMF2");
        assertEq(s.spoke.shareToken(POOL_A, SC_1).hook(), address(s.fullRestrictionsHook));
    }

    /// forge-config: default.isolate = true
    function testFullRefundSubsidizedCycle() public {
        _setSpoke(false);
        _createPool();

        vm.startPrank(FM);
        h.hub.notifyPool(POOL_A, s.centrifugeId);
        h.hub.notifyShareClass(POOL_A, SC_1, s.centrifugeId, address(0).toBytes32());
        h.hub.updateBalanceSheetManager(s.centrifugeId, POOL_A, BSM.toBytes32(), true);
        h.hub.updateSharePrice(POOL_A, SC_1, IntegrationConstants.zeroPrice());
        h.hub.notifySharePrice(POOL_A, SC_1, s.centrifugeId);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);

        // Each message will return half of the gas wasted
        adapterBToA.setRefundedValue(h.gasService.updateShares() / 2);

        // We just subsidize for two message
        vm.startPrank(ANY);
        s.gateway.depositSubsidy{value: h.gasService.updateShares() * 2}(POOL_A);
        assertEq(address(s.balanceSheet.escrow(POOL_A)).balance, 0);
        assertEq(address(s.gateway).balance, DEFAULT_SUBSIDY + h.gasService.updateShares() * 2);

        vm.startPrank(BSM);
        s.balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);
        assertEq(address(s.balanceSheet.escrow(POOL_A)).balance, h.gasService.updateShares() / 2);
        assertEq(address(s.gateway).balance, DEFAULT_SUBSIDY + h.gasService.updateShares());

        s.balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);
        assertEq(address(s.balanceSheet.escrow(POOL_A)).balance, h.gasService.updateShares());
        assertEq(address(s.gateway).balance, DEFAULT_SUBSIDY);

        // This message is fully paid with refunded amount
        s.balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);
        assertEq(address(s.balanceSheet.escrow(POOL_A)).balance, h.gasService.updateShares() / 2);
        assertEq(address(s.gateway).balance, DEFAULT_SUBSIDY);

        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), 3, "3 UpdateShares messages received");
    }

    /// forge-config: default.isolate = true
    function testUpdatePriceAge(bool sameChain) public {
        _configurePool(sameChain);

        vm.startPrank(FM);

        h.hub.setMaxAssetPriceAge(POOL_A, SC_1, s.usdcId, uint64(block.timestamp));
        h.hub.setMaxSharePriceAge(s.centrifugeId, POOL_A, SC_1, uint64(block.timestamp));

        (,, uint64 validUntil) = s.spoke.markersPricePoolPerAsset(POOL_A, SC_1, s.usdcId);
        assertEq(validUntil, uint64(block.timestamp));

        (,, validUntil) = s.spoke.markersPricePoolPerShare(POOL_A, SC_1);
        assertEq(validUntil, uint64(block.timestamp));
    }

    /// forge-config: default.isolate = true
    function testFundManagement(bool sameChain) public {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, USDC_AMOUNT_1);

        vm.startPrank(BSM);
        s.usdc.approve(address(s.balanceSheet), USDC_AMOUNT_1);
        s.balanceSheet.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);
        s.balanceSheet.withdraw(POOL_A, SC_1, address(s.usdc), 0, BSM, USDC_AMOUNT_1 * 4 / 5);
        s.balanceSheet.submitQueuedAssets(POOL_A, SC_1, s.usdcId, EXTRA_GAS);

        // CHECKS
        assertEq(s.usdc.balanceOf(BSM), USDC_AMOUNT_1 * 4 / 5);
        assertEq(s.balanceSheet.availableBalanceOf(POOL_A, SC_1, address(s.usdc), 0), USDC_AMOUNT_1 / 5);

        (uint128 amount, uint128 value,,) = h.holdings.holding(POOL_A, SC_1, s.usdcId);
        assertEq(amount, USDC_AMOUNT_1 / 5);
        assertEq(value, assetToPool(USDC_AMOUNT_1 / 5));

        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), 1);

        checkAccountValue(ASSET_ACCOUNT, assetToPool(USDC_AMOUNT_1 / 5), true);
        checkAccountValue(EQUITY_ACCOUNT, assetToPool(USDC_AMOUNT_1 / 5), true);
    }

    /// forge-config: default.isolate = true
    function testVaultManagement(bool sameChain) public {
        _configurePool(sameChain);

        vm.startPrank(FM);
        h.hub.updateVault(POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS);

        address vault = address(s.spoke.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager));

        h.hub.updateVault(POOL_A, SC_1, s.usdcId, vault.toBytes32(), VaultUpdateKind.Unlink, EXTRA_GAS);

        assertEq(s.spoke.isLinked(IVault(vault)), false);

        h.hub.updateVault(POOL_A, SC_1, s.usdcId, vault.toBytes32(), VaultUpdateKind.Link, EXTRA_GAS);

        assertEq(s.spoke.isLinked(IVault(vault)), true);
    }

    /// forge-config: default.isolate = true
    function testAsyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testAsyncDeposit(sameChain, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testSyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testSyncDeposit(sameChain, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testAsyncDepositCancel(bool sameChain, bool nonZeroPrices) public {
        _configurePool(sameChain);
        nonZeroPrices
            ? _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice())
            : _configurePrices(IntegrationConstants.zeroPrice(), IntegrationConstants.zeroPrice());

        vm.startPrank(FM);
        h.hub.updateVault(POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS);

        IAsyncVault vault = IAsyncVault(address(s.spoke.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager)));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vault.cancelDepositRequest(PLACEHOLDER_REQUEST_ID, INVESTOR_A);
        vault.claimCancelDepositRequest(PLACEHOLDER_REQUEST_ID, INVESTOR_A, INVESTOR_A);

        // CHECKS
        assertEq(s.usdc.balanceOf(INVESTOR_A), USDC_AMOUNT_1, "expected assets");
    }

    /// forge-config: default.isolate = true
    function testAsyncRedeem_AfterAsyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testAsyncRedeem(sameChain, true, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testAsyncRedeem_AfterSyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testAsyncRedeem(sameChain, false, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testAsyncRedeemCancel_AfterAsyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testAsyncRedeemCancel(sameChain, true, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testAsyncRedeemCancel_AfterSyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testAsyncRedeemCancel(sameChain, false, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testUpdateAccountingAfterDeposit_AfterAsyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testUpdateAccountingAfterDeposit(sameChain, true, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testUpdateAccountingAfterDeposit_AfterSyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _testUpdateAccountingAfterDeposit(sameChain, false, nonZeroPrices);
    }

    /// forge-config: default.isolate = true
    function testUpdateAccountingAfterRedeem_AfterAsyncDeposit(bool sameChain) public {
        _testUpdateAccountingAfterRedeem(sameChain, true);
    }

    /// forge-config: default.isolate = true
    function testUpdateAccountingAfterRedeem_AfterSyncDeposit(bool sameChain) public {
        _testUpdateAccountingAfterRedeem(sameChain, false);
    }

    /// forge-config: default.isolate = true
    function testAdaptersPerPool() public {
        _configureBasePoolWithCustomAdapters();

        vm.startPrank(FM);
        h.hub.notifyPool(POOL_A, s.centrifugeId);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);

        // Hub -> Spoke message went through the pool adapter
        assertEq(uint8(poolAdapterAToB.lastReceivedPayload().messageType()), uint8(MessageType.NotifyPool));
        assertEq(s.spoke.pool(POOL_A), block.timestamp); // Message received and processed

        h.hub.updateBalanceSheetManager(s.centrifugeId, POOL_A, BSM.toBytes32(), true);

        vm.startPrank(ANY);
        s.gateway.depositSubsidy{value: DEFAULT_SUBSIDY}(POOL_A);

        vm.startPrank(BSM);
        s.balanceSheet.submitQueuedShares(POOL_A, SC_1, EXTRA_GAS);

        // Spoke -> Hub message went through the pool adapter
        assertEq(uint8(poolAdapterBToA.lastReceivedPayload().messageType()), uint8(MessageType.UpdateShares));

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
        h.hub.setAdapters(s.centrifugeId, POOL_A, localAdapters, remoteAdapters, 1, 1);
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
        h.hub.setAdapters(h.centrifugeId, POOL_A, localAdapters, remoteAdapters, 1, 1);
    }

    /// forge-config: default.isolate = true
    function testAdaptersWithRecovery() public {
        _setSpoke(IN_DIFFERENT_CHAINS);
        _createPool();

        // Wire pool adapters
        poolAdapterAToB = new LocalAdapter(h.centrifugeId, h.multiAdapter, FM);
        poolAdapterBToA = new LocalAdapter(s.centrifugeId, s.multiAdapter, FM);

        poolAdapterAToB.setEndpoint(poolAdapterBToA);
        poolAdapterBToA.setEndpoint(poolAdapterAToB);

        IAdapter[] memory localAdapters = new IAdapter[](2);
        localAdapters[0] = poolAdapterAToB;
        localAdapters[1] = new RecoveryAdapter(h.multiAdapter, FM);

        bytes32[] memory remoteAdapters = new bytes32[](2);
        remoteAdapters[0] = address(poolAdapterBToA).toBytes32();
        remoteAdapters[1] = address(new RecoveryAdapter(s.multiAdapter, FM)).toBytes32();

        vm.startPrank(FM);

        uint8 threshold = 2;
        uint8 recoveryIndex = 1;
        h.hub.setAdapters(s.centrifugeId, POOL_A, localAdapters, remoteAdapters, threshold, recoveryIndex);

        // Only local adapter will send the message, recovery adapter will skip it.
        h.hub.notifyPool(POOL_A, s.centrifugeId);

        assertEq(s.spoke.pool(POOL_A), 0); // 1 of 2 received, not processed yet

        bytes memory message = MessageLib.NotifyPool({poolId: POOL_A.raw()}).serialize();

        // In the remote recovery adapter, we recover the message
        IMessageHandler(remoteAdapters[1].toAddress()).handle(h.centrifugeId, message);

        assertEq(s.spoke.pool(POOL_A), block.timestamp); // 2 of 2 received and processed
    }
}
