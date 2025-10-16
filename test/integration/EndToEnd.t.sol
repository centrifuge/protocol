// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {VMLabeling} from "./utils/VMLabeling.sol";
import {LocalAdapter} from "./adapters/LocalAdapter.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {D18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {Hub} from "../../src/core/hub/Hub.sol";
import {Spoke} from "../../src/core/spoke/Spoke.sol";
import {PoolId} from "../../src/core/types/PoolId.sol";
import {Holdings} from "../../src/core/hub/Holdings.sol";
import {AccountId} from "../../src/core/types/AccountId.sol";
import {Accounting} from "../../src/core/hub/Accounting.sol";
import {Gateway} from "../../src/core/messaging/Gateway.sol";
import {HubHandler} from "../../src/core/hub/HubHandler.sol";
import {HubRegistry} from "../../src/core/hub/HubRegistry.sol";
import {IVault} from "../../src/core/spoke/interfaces/IVault.sol";
import {BalanceSheet} from "../../src/core/spoke/BalanceSheet.sol";
import {GasService} from "../../src/core/messaging/GasService.sol";
import {PricingLib} from "../../src/core/libraries/PricingLib.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {VaultRegistry} from "../../src/core/spoke/VaultRegistry.sol";
import {IAdapter} from "../../src/core/messaging/interfaces/IAdapter.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {ShareClassManager} from "../../src/core/hub/ShareClassManager.sol";
import {MAX_MESSAGE_COST} from "../../src/core/messaging/interfaces/IGasService.sol";
import {IHubRequestManager} from "../../src/core/hub/interfaces/IHubRequestManager.sol";
import {IMessageHandler} from "../../src/core/messaging/interfaces/IMessageHandler.sol";
import {MultiAdapter, MAX_ADAPTER_COUNT} from "../../src/core/messaging/MultiAdapter.sol";
import {ILocalCentrifugeId} from "../../src/core/messaging/interfaces/IGatewaySenders.sol";
import {IUntrustedContractUpdate} from "../../src/core/utils/interfaces/IContractUpdate.sol";
import {MessageLib, MessageType, VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {Root} from "../../src/admin/Root.sol";
import {ISafe} from "../../src/admin/interfaces/ISafe.sol";
import {OpsGuardian} from "../../src/admin/OpsGuardian.sol";
import {ProtocolGuardian} from "../../src/admin/ProtocolGuardian.sol";

import {MockSnapshotHook} from "../hooks/mocks/MockSnapshotHook.sol";

import {FreezeOnly} from "../../src/hooks/FreezeOnly.sol";
import {FullRestrictions} from "../../src/hooks/FullRestrictions.sol";
import {RedemptionRestrictions} from "../../src/hooks/RedemptionRestrictions.sol";
import {UpdateRestrictionMessageLib} from "../../src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {OracleValuation} from "../../src/valuations/OracleValuation.sol";
import {IdentityValuation} from "../../src/valuations/IdentityValuation.sol";

import {SyncManager} from "../../src/vaults/SyncManager.sol";
import {VaultRouter} from "../../src/vaults/VaultRouter.sol";
import {IBaseVault} from "../../src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {ISyncManager} from "../../src/vaults/interfaces/IVaultManagers.sol";
import {AsyncRequestManager} from "../../src/vaults/AsyncRequestManager.sol";
import {BatchRequestManager} from "../../src/vaults/BatchRequestManager.sol";
import {IAsyncRedeemVault} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {RefundEscrowFactory} from "../../src/vaults/factories/RefundEscrowFactory.sol";

import {FullActionBatcher, FullDeployer, FullInput, noAdaptersInput, CoreInput} from "../../script/FullDeployer.s.sol";

import "forge-std/Test.sol";

import {RecoveryAdapter} from "../../src/adapters/RecoveryAdapter.sol";

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
        BatchRequestManager batchRequestManager;
        // Others
        IdentityValuation identityValuation;
        OracleValuation oracleValuation;
        MockSnapshotHook snapshotHook;
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
        BalanceSheet balanceSheet;
        Spoke spoke;
        VaultRegistry vaultRegistry;
        // Vaults
        VaultRouter router;
        bytes32 asyncVaultFactory;
        bytes32 syncDepositVaultFactory;
        AsyncRequestManager asyncRequestManager;
        SyncManager syncManager;
        RefundEscrowFactory refundEscrowFactory;
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
            batchRequestManager: deployA.batchRequestManager(),
            identityValuation: deployA.identityValuation(),
            oracleValuation: deployA.oracleValuation(),
            snapshotHook: new MockSnapshotHook()
        });

        // Initialize default values
        USD_ID = deployA.USD_ID();
        POOL_A = h.hubRegistry.poolId(CENTRIFUGE_ID_A, 1);
        SC_1 = h.shareClassManager.previewNextShareClassId(POOL_A);

        vm.label(address(adapterAToB), "AdapterAToB");
        vm.label(address(adapterBToA), "AdapterBToA");

        vm.recordLogs();
    }

    function _setAdapter(FullDeployer deploy, uint16 remoteCentrifugeId, IAdapter adapter) internal {
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = adapter;
        vm.startPrank(address(deploy.protocolGuardian()));
        deploy.multiAdapter()
            .setAdapters(remoteCentrifugeId, GLOBAL_POOL, adapters, uint8(adapters.length), uint8(adapters.length));

        vm.startPrank(address(deploy.protocolGuardian()));
        deploy.gateway().updateManager(GLOBAL_POOL, GATEWAY_MANAGER, true);
        vm.stopPrank();
    }

    function _deployChain(FullDeployer deploy, uint16 localCentrifugeId, uint16 remoteCentrifugeId, ISafe adminSafe)
        internal
        returns (LocalAdapter adapter)
    {
        FullActionBatcher batcher = new FullActionBatcher();
        batcher.setDeployer(address(deploy));

        deploy.labelAddresses(string(abi.encodePacked(localCentrifugeId, "-")));
        deploy.deployFull(
            FullInput({
                core: CoreInput({
                    centrifugeId: localCentrifugeId,
                    version: bytes32(abi.encodePacked(localCentrifugeId)),
                    root: address(0)
                }),
                adminSafe: adminSafe,
                opsSafe: adminSafe,
                adapters: noAdaptersInput()
            }),
            batcher
        );

        adapter = new LocalAdapter(localCentrifugeId, deploy.multiAdapter(), address(deploy));
        _setAdapter(deploy, remoteCentrifugeId, adapter);

        deploy.removeFullDeployerAccess(batcher);
    }

    function _setSpoke(FullDeployer deploy, uint16 centrifugeId, CSpoke storage s_) internal {
        if (s_.centrifugeId != 0) return; // Already set

        s_.centrifugeId = centrifugeId;
        s_.root = deploy.root();
        s_.protocolGuardian = deploy.protocolGuardian();
        s_.opsGuardian = deploy.opsGuardian();
        s_.gateway = deploy.gateway();
        s_.multiAdapter = deploy.multiAdapter();
        s_.balanceSheet = deploy.balanceSheet();
        s_.spoke = deploy.spoke();
        s_.vaultRegistry = deploy.vaultRegistry();
        s_.router = deploy.vaultRouter();
        s_.freezeOnlyHook = deploy.freezeOnlyHook();
        s_.fullRestrictionsHook = deploy.fullRestrictionsHook();
        s_.redemptionRestrictionsHook = deploy.redemptionRestrictionsHook();
        s_.asyncVaultFactory = address(deploy.asyncVaultFactory()).toBytes32();
        s_.syncDepositVaultFactory = address(deploy.syncDepositVaultFactory()).toBytes32();
        s_.asyncRequestManager = deploy.asyncRequestManager();
        s_.syncManager = deploy.syncManager();
        s_.refundEscrowFactory = deploy.refundEscrowFactory();
        s_.usdc = new ERC20(6);
        s_.usdcId = newAssetId(centrifugeId, 1);

        // Initialize default values
        s_.usdc.file("name", "USD Coin");
        s_.usdc.file("symbol", "USDC");

        s_.asyncRequestManager.depositSubsidy{value: 0.5 ether}(POOL_A);
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

    function _updateContractSyncDepositMaxReserveMsg(uint128 maxReserve) internal view returns (bytes memory) {
        return abi.encode(uint8(ISyncManager.TrustedCall.MaxReserve), s.usdcId.raw(), maxReserve);
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

    function _createPool() internal {
        vm.startPrank(address(h.protocolGuardian.safe()));
        h.opsGuardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32("salt"));

        _createPoolAccounts();
    }

    function _configureAsset(CSpoke memory s_) internal {
        vm.startPrank(ERC20_DEPLOYER);
        s_.usdc.mint(INVESTOR_A, USDC_AMOUNT_1);

        vm.startPrank(ANY);
        s_.spoke.registerAsset{value: GAS}(h.centrifugeId, address(s_.usdc), 0, ANY);
    }

    function _configurePool(CSpoke memory s_) internal {
        _configureAsset(s_);

        if (!h.hubRegistry.exists(POOL_A)) {
            _createPool();
        }

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, s_.centrifugeId, REFUND);
        h.hub
        .notifyShareClass{
            value: GAS
        }(POOL_A, SC_1, s_.centrifugeId, address(s_.redemptionRestrictionsHook).toBytes32(), REFUND);

        h.hub
            .initializeHolding(
                POOL_A, SC_1, s_.usdcId, h.oracleValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
            );
        h.hub
        .setRequestManager{
            value: GAS
        }(
            POOL_A,
            s_.centrifugeId,
            IHubRequestManager(h.batchRequestManager),
            address(s_.asyncRequestManager).toBytes32(),
            REFUND
        );
        h.hub
        .updateBalanceSheetManager{
            value: GAS
        }(POOL_A, s_.centrifugeId, address(s_.asyncRequestManager).toBytes32(), true, REFUND);
        h.hub
        .updateBalanceSheetManager{
            value: GAS
        }(POOL_A, s_.centrifugeId, address(s_.syncManager).toBytes32(), true, REFUND);
        h.hub.updateBalanceSheetManager{value: GAS}(POOL_A, s_.centrifugeId, BSM.toBytes32(), true, REFUND);

        vm.startPrank(FM);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);
        h.oracleValuation.updateFeeder(POOL_A, FEEDER, true);
        h.hub.updateHubManager(POOL_A, address(h.oracleValuation), true);
        h.hub
        .updateGatewayManager{
            value: GAS
        }(POOL_A, h.centrifugeId, address(h.batchRequestManager).toBytes32(), true, REFUND);
        vm.stopPrank();
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
        h.hub.setAdapters{value: GAS}(POOL_A, s.centrifugeId, localAdapters, remoteAdapters, 1, 1, REFUND);
        h.hub.updateGatewayManager{value: GAS}(POOL_A, h.centrifugeId, GATEWAY_MANAGER.toBytes32(), true, REFUND);
        h.hub.updateGatewayManager{value: GAS}(POOL_A, s.centrifugeId, GATEWAY_MANAGER.toBytes32(), true, REFUND);
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

    function _testAsyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _configurePool(sameChain);
        _configurePricesForFlow(nonZeroPrices);

        vm.startPrank(FM);
        h.hub
        .updateVault{
            value: GAS
        }(POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS, REFUND);
        vm.stopPrank();
        IAsyncVault vault = IAsyncVault(address(s.vaultRegistry.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager)));

        vm.startPrank(INVESTOR_A);
        ERC20(vault.asset()).approve(address(vault), USDC_AMOUNT_1);
        vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);

        vm.startPrank(FM);
        uint32 depositEpochId = h.batchRequestManager.nowDepositEpoch(POOL_A, SC_1, s.usdcId);
        D18 pricePoolPerAsset = h.hub.pricePoolPerAsset(POOL_A, SC_1, s.usdcId);
        h.batchRequestManager
        .approveDeposits{value: GAS}(POOL_A, SC_1, s.usdcId, depositEpochId, USDC_AMOUNT_1, pricePoolPerAsset, REFUND);

        vm.startPrank(FM);
        uint32 issueEpochId = h.batchRequestManager.nowIssueEpoch(POOL_A, SC_1, s.usdcId);
        (D18 sharePrice,) = h.shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        h.batchRequestManager
        .issueShares{value: GAS}(POOL_A, SC_1, s.usdcId, issueEpochId, sharePrice, HOOK_GAS, REFUND);

        vm.startPrank(ANY);
        h.batchRequestManager
        .notifyDeposit{
            value: GAS
        }(
            POOL_A,
            SC_1,
            s.usdcId,
            INVESTOR_A.toBytes32(),
            h.batchRequestManager.maxDepositClaims(POOL_A, SC_1, INVESTOR_A.toBytes32(), s.usdcId),
            REFUND
        );

        vm.startPrank(INVESTOR_A);
        vault.mint(vault.maxMint(INVESTOR_A), INVESTOR_A);

        // CHECKS
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "expected shares");
    }

    function _testSyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _configurePool(sameChain);
        _configurePricesForFlow(nonZeroPrices);

        vm.startPrank(FM);
        h.hub
        .updateVault{
            value: GAS
        }(POOL_A, SC_1, s.usdcId, s.syncDepositVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS, REFUND);
        IBaseVault vault = IBaseVault(address(s.vaultRegistry.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager)));

        h.hub
        .updateContract{
            value: GAS
        }(
            POOL_A,
            SC_1,
            s.centrifugeId,
            address(s.syncManager).toBytes32(),
            _updateContractSyncDepositMaxReserveMsg(type(uint128).max),
            EXTRA_GAS,
            REFUND
        );

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);

        if (!nonZeroPrices) {
            // When prices are zero, maxDeposit returns 0, so deposit will revert
            vm.expectRevert(ISyncManager.ExceedsMaxDeposit.selector);
            vault.deposit(USDC_AMOUNT_1, INVESTOR_A);
            return;
        }

        vault.deposit(USDC_AMOUNT_1, INVESTOR_A);

        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "expected shares");
    }

    function _testAsyncRedeem(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) internal {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, true) : _testSyncDeposit(sameChain, true);
        _configurePricesForFlow(nonZeroPrices);

        vm.startPrank(FM);
        h.hub
        .updateRestriction{
            value: GAS
        }(POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND);

        // Get vault from manager
        IAsyncRedeemVault vault =
            IAsyncRedeemVault(address(s.vaultRegistry.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager)));

        vm.startPrank(INVESTOR_A);
        uint128 shares = uint128(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A));
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);

        vm.startPrank(FM);
        uint32 redeemEpochId = h.batchRequestManager.nowRedeemEpoch(POOL_A, SC_1, s.usdcId);
        D18 pricePoolPerAsset = h.hub.pricePoolPerAsset(POOL_A, SC_1, s.usdcId);
        h.batchRequestManager.approveRedeems(POOL_A, SC_1, s.usdcId, redeemEpochId, shares, pricePoolPerAsset);

        vm.startPrank(FM);
        uint32 revokeEpochId = h.batchRequestManager.nowRevokeEpoch(POOL_A, SC_1, s.usdcId);
        (D18 sharePrice,) = h.shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        h.batchRequestManager
        .revokeShares{value: GAS}(POOL_A, SC_1, s.usdcId, revokeEpochId, sharePrice, HOOK_GAS, REFUND);

        vm.startPrank(ANY);
        h.batchRequestManager
        .notifyRedeem{
            value: GAS
        }(
            POOL_A,
            SC_1,
            s.usdcId,
            INVESTOR_A.toBytes32(),
            h.batchRequestManager.maxRedeemClaims(POOL_A, SC_1, INVESTOR_A.toBytes32(), s.usdcId),
            REFUND
        );

        vm.startPrank(INVESTOR_A);
        vault.withdraw(vault.maxWithdraw(INVESTOR_A), INVESTOR_A, INVESTOR_A);

        assertEq(s.usdc.balanceOf(INVESTOR_A), shareToAsset(shares), "expected assets");
    }

    //----------------------------------------------------------------------------------------------
    // Test Cancellation & Edge Cases
    //----------------------------------------------------------------------------------------------

    function _testAsyncRedeemCancel(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) public {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, true) : _testSyncDeposit(sameChain, true);
        uint128 expectedShares = assetToShare(USDC_AMOUNT_1);

        _configurePricesForFlow(nonZeroPrices);

        vm.startPrank(FM);
        h.hub
        .updateRestriction{
            value: GAS
        }(POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS, REFUND);

        IAsyncRedeemVault vault =
            IAsyncRedeemVault(address(s.vaultRegistry.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager)));

        vm.startPrank(INVESTOR_A);
        uint128 shares = uint128(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A));
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);
        vault.cancelRedeemRequest(PLACEHOLDER_REQUEST_ID, INVESTOR_A);

        if (!sameChain) h.gateway.repay{value: GAS}(s.centrifugeId, _getLastUnpaidMessage(), REFUND);

        vault.claimCancelRedeemRequest(PLACEHOLDER_REQUEST_ID, INVESTOR_A, INVESTOR_A);

        // CHECKS
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), expectedShares, "expected shares");
    }

    function _testUpdateAccountingAfterDeposit(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) public {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, nonZeroPrices) : _testSyncDeposit(sameChain, nonZeroPrices);

        // If prices are zero and using sync deposit, the deposit failed
        if (!nonZeroPrices && !afterAsyncDeposit) {
            return;
        }

        vm.startPrank(BSM);
        s.balanceSheet.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, EXTRA_GAS, REFUND);
        s.balanceSheet.submitQueuedShares{value: GAS}(POOL_A, SC_1, EXTRA_GAS, REFUND);

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
        s.balanceSheet.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, EXTRA_GAS, REFUND);
        s.balanceSheet.submitQueuedShares{value: GAS}(POOL_A, SC_1, EXTRA_GAS, REFUND);

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
        h.protocolGuardian.scheduleUpgrade{value: GAS}(s.centrifugeId, NEW_WARD, REFUND);
        h.protocolGuardian.cancelUpgrade{value: GAS}(s.centrifugeId, NEW_WARD, REFUND);
        h.protocolGuardian.scheduleUpgrade{value: GAS}(s.centrifugeId, NEW_WARD, REFUND);

        vm.warp(block.timestamp + deployA.DELAY() + 1000);

        vm.startPrank(ANY);
        s.root.executeScheduledRely(NEW_WARD);
    }

    /// forge-config: default.isolate = true
    function testTokenRecover(bool sameChain) public {
        address RECEIVER = makeAddr("Receiver");
        uint256 VALUE = 123;

        _setSpoke(sameChain);

        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(address(s.gateway), VALUE);

        vm.startPrank(address(SAFE_ADMIN_A));
        h.protocolGuardian
        .recoverTokens{value: GAS}(s.centrifugeId, address(s.gateway), address(s.usdc), 0, RECEIVER, VALUE, REFUND);

        assertEq(s.usdc.balanceOf(RECEIVER), VALUE);
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
        h.hub.notifyShareMetadata{value: GAS}(POOL_A, SC_1, s.centrifugeId, REFUND);
        h.hub
        .updateShareHook{value: GAS}(POOL_A, SC_1, s.centrifugeId, address(s.fullRestrictionsHook).toBytes32(), REFUND);

        assertEq(s.spoke.shareToken(POOL_A, SC_1).name(), "Tokenized MMF 2");
        assertEq(s.spoke.shareToken(POOL_A, SC_1).symbol(), "MMF2");
        assertEq(s.spoke.shareToken(POOL_A, SC_1).hook(), address(s.fullRestrictionsHook));
    }

    /// forge-config: default.isolate = true
    function testUpdatePriceAge(bool sameChain) public {
        _configurePool(sameChain);

        vm.startPrank(FM);

        h.hub.setMaxAssetPriceAge{value: GAS}(POOL_A, SC_1, s.usdcId, uint64(block.timestamp), REFUND);
        h.hub.setMaxSharePriceAge{value: GAS}(POOL_A, SC_1, s.centrifugeId, uint64(block.timestamp), REFUND);

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
        s.balanceSheet.submitQueuedAssets{value: GAS}(POOL_A, SC_1, s.usdcId, EXTRA_GAS, REFUND);

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
        h.hub
        .updateVault{
            value: GAS
        }(POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS, REFUND);

        address vault = address(s.vaultRegistry.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager));

        h.hub
        .updateVault{value: GAS}(POOL_A, SC_1, s.usdcId, vault.toBytes32(), VaultUpdateKind.Unlink, EXTRA_GAS, REFUND);

        assertEq(s.vaultRegistry.isLinked(IVault(vault)), false);

        h.hub
        .updateVault{value: GAS}(POOL_A, SC_1, s.usdcId, vault.toBytes32(), VaultUpdateKind.Link, EXTRA_GAS, REFUND);

        assertEq(s.vaultRegistry.isLinked(IVault(vault)), true);
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
        _configurePricesForFlow(nonZeroPrices);

        vm.startPrank(FM);
        h.hub
        .updateVault{
            value: GAS
        }(POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS, REFUND);

        IAsyncVault vault = IAsyncVault(address(s.vaultRegistry.vault(POOL_A, SC_1, s.usdcId, s.asyncRequestManager)));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vault.cancelDepositRequest(PLACEHOLDER_REQUEST_ID, INVESTOR_A);

        if (!sameChain) h.gateway.repay{value: GAS}(s.centrifugeId, _getLastUnpaidMessage(), REFUND);

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
        h.hub.notifyPool{value: GAS}(POOL_A, s.centrifugeId, REFUND);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);

        // Hub -> Spoke message went through the pool adapter
        assertEq(uint8(poolAdapterAToB.lastReceivedPayload().messageType()), uint8(MessageType.NotifyPool));
        assertEq(s.spoke.pool(POOL_A), block.timestamp); // Message received and processed

        h.hub.updateBalanceSheetManager{value: GAS}(POOL_A, s.centrifugeId, BSM.toBytes32(), true, REFUND);

        vm.startPrank(BSM);
        s.balanceSheet.submitQueuedShares{value: GAS}(POOL_A, SC_1, EXTRA_GAS, REFUND);

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
        h.hub.setAdapters{value: GAS}(POOL_A, s.centrifugeId, localAdapters, remoteAdapters, 1, 1, REFUND);
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
        h.hub.setAdapters{value: GAS}(POOL_A, h.centrifugeId, localAdapters, remoteAdapters, 1, 1, REFUND);
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
        h.hub
        .setAdapters{
            value: GAS
        }(POOL_A, s.centrifugeId, localAdapters, remoteAdapters, threshold, recoveryIndex, REFUND);

        // Only local adapter will send the message, recovery adapter will skip it.
        h.hub.notifyPool{value: GAS}(POOL_A, s.centrifugeId, REFUND);

        assertEq(s.spoke.pool(POOL_A), 0); // 1 of 2 received, not processed yet

        bytes memory message = MessageLib.NotifyPool({poolId: POOL_A.raw()}).serialize();

        // In the remote recovery adapter, we recover the message
        IMessageHandler(remoteAdapters[1].toAddress()).handle(h.centrifugeId, message);

        assertEq(s.spoke.pool(POOL_A), block.timestamp); // 2 of 2 received and processed
    }

    /// forge-config: default.isolate = true
    function testWithdrawSubsidyFromVaults(bool sameChain) public {
        _configurePool(sameChain);

        address RECEIVER = makeAddr("Receiver");
        uint256 VALUE = 123;

        vm.startPrank(FM);
        h.hub
        .updateContract{
            value: GAS
        }(
            POOL_A,
            SC_1,
            s.centrifugeId,
            address(s.asyncRequestManager).toBytes32(),
            abi.encode(RECEIVER.toBytes32(), VALUE),
            EXTRA_GAS,
            REFUND
        );

        assertEq(RECEIVER.balance, VALUE);
    }

    /// forge-config: default.isolate = true
    function testUntrustedContractUpdate(bool sameChain) public {
        _setSpoke(sameChain);

        address hubContract = address(new IsContract());
        address spokeSender = makeAddr("SpokeSender");

        vm.mockCall(
            hubContract,
            abi.encodeWithSelector(
                IUntrustedContractUpdate.untrustedCall.selector,
                POOL_A,
                SC_1,
                "data",
                s.centrifugeId,
                spokeSender.toBytes32()
            ),
            abi.encode()
        );

        vm.startPrank(spokeSender);
        vm.deal(spokeSender, GAS);
        s.spoke.updateContract{value: GAS}(POOL_A, SC_1, hubContract.toBytes32(), "data", EXTRA_GAS, REFUND);
    }
}
