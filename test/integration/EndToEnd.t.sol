// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IAuth} from "src/misc/interfaces/IAuth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";

import {Root} from "src/common/Root.sol";
import {Gateway} from "src/common/Gateway.sol";
import {Guardian} from "src/common/Guardian.sol";
import {PoolId} from "src/common/types/PoolId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {IAdapter} from "src/common/interfaces/IAdapter.sol";
import {PricingLib} from "src/common/libraries/PricingLib.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {SyncManager} from "src/vaults/SyncManager.sol";
import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IAsyncVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {IAsyncRedeemVault} from "src/vaults/interfaces/IAsyncVault.sol";

import {Hub} from "src/hub/Hub.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";

import {Spoke} from "src/spoke/Spoke.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {UpdateContractMessageLib} from "src/spoke/libraries/UpdateContractMessageLib.sol";

import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {FullDeployer, CommonInput} from "script/FullDeployer.s.sol";

import {MockValuation} from "test/common/mocks/MockValuation.sol";
import {MockSnapshotHook} from "test/hooks/mocks/MockSnapshotHook.sol";
import {LocalAdapter} from "test/integration/adapters/LocalAdapter.sol";

import "forge-std/Test.sol";

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
        // Hub
        HubRegistry hubRegistry;
        Accounting accounting;
        Holdings holdings;
        ShareClassManager shareClassManager;
        Hub hub;
        // Others
        IdentityValuation identityValuation;
        MockValuation valuation;
        MockSnapshotHook snapshotHook;
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
        bytes32 asyncVaultFactory;
        bytes32 syncDepositVaultFactory;
        AsyncRequestManager asyncRequestManager;
        SyncManager syncManager;
        // Hooks
        address fullRestrictionsHook;
        address redemptionRestrictionsHook;
        // Others
        ERC20 usdc;
        AssetId usdcId;
    }

    ISafe immutable safeAdminA = ISafe(makeAddr("SafeAdminA"));
    ISafe immutable safeAdminB = ISafe(makeAddr("SafeAdminB"));

    uint16 constant CENTRIFUGE_ID_A = 5;
    uint16 constant CENTRIFUGE_ID_B = 6;
    uint64 constant GAS = 10 wei;
    uint256 constant DEFAULT_SUBSIDY = 0.1 ether;

    address immutable DEPLOYER = address(this);
    address immutable FM = makeAddr("FM");
    address immutable BSM = makeAddr("BSM");
    address immutable INVESTOR_A = makeAddr("INVESTOR_A");
    address immutable ANY = makeAddr("ANY");

    uint128 constant USDC_AMOUNT_1 = 1_000_000e6; // Measured in USDC: 1M of USDC

    AccountId constant ASSET_ACCOUNT = AccountId.wrap(0x01);
    AccountId constant EQUITY_ACCOUNT = AccountId.wrap(0x02);
    AccountId constant LOSS_ACCOUNT = AccountId.wrap(0x03);
    AccountId constant GAIN_ACCOUNT = AccountId.wrap(0x04);

    AssetId USD_ID;
    PoolId POOL_A;
    ShareClassId SC_1;

    FullDeployer deployA = new FullDeployer();
    FullDeployer deployB = new FullDeployer();

    LocalAdapter adapterAToB;
    LocalAdapter adapterBToA;

    CHub h;
    CSpoke s;

    D18 immutable ZERO_PRICE = d18(0);
    D18 immutable IDENTITY_PRICE = d18(1, 1);
    D18 immutable TEN_PERCENT = d18(1, 10);
    D18 immutable ASSET_PRICE = d18(1, 2);
    D18 immutable SHARE_PRICE = d18(4, 1);

    uint8 constant USDC_DECIMALS = 6;
    uint8 constant POOL_DECIMALS = 18;
    uint8 constant SHARE_DECIMALS = POOL_DECIMALS;

    uint256 constant PLACEHOLDER = 0;
    uint128 constant EXTRA_GAS = 0;

    // Set by _configurePrices and read by pricing utilities
    D18 currentAssetPrice = IDENTITY_PRICE;
    D18 currentSharePrice = IDENTITY_PRICE;

    function setUp() public virtual {
        adapterAToB = _deployChain(deployA, CENTRIFUGE_ID_A, CENTRIFUGE_ID_B, safeAdminA);
        adapterBToA = _deployChain(deployB, CENTRIFUGE_ID_B, CENTRIFUGE_ID_A, safeAdminB);

        // We connect both deploys through the adapters
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
            hubRegistry: deployA.hubRegistry(),
            accounting: deployA.accounting(),
            holdings: deployA.holdings(),
            shareClassManager: deployA.shareClassManager(),
            hub: deployA.hub(),
            identityValuation: deployA.identityValuation(),
            valuation: new MockValuation(deployA.hubRegistry()),
            snapshotHook: new MockSnapshotHook()
        });

        // Initialize default values
        USD_ID = deployA.USD_ID();
        POOL_A = h.hubRegistry.poolId(CENTRIFUGE_ID_A, 1);
        SC_1 = h.shareClassManager.previewNextShareClassId(POOL_A);

        vm.label(address(adapterAToB), "AdapterAToB");
        vm.label(address(adapterBToA), "AdapterBToA");
        vm.label(address(h.hub), "Hub");
    }

    function _wire(FullDeployer deploy, uint16 remoteCentrifugeId, IAdapter adapter) internal {
        vm.startPrank(address(deploy));
        IAuth(address(adapter)).rely(address(deploy.root()));
        IAuth(address(adapter)).rely(address(deploy.guardian()));
        IAuth(address(adapter)).deny(address(deploy));
        vm.stopPrank();

        vm.startPrank(address(deploy.guardian().safe()));
        IAdapter[] memory adapters = new IAdapter[](1);
        adapters[0] = adapter;
        deploy.guardian().wireAdapters(remoteCentrifugeId, adapters);
        vm.stopPrank();
    }

    function _deployChain(FullDeployer deploy, uint16 localCentrifugeId, uint16 remoteCentrifugeId, ISafe adminSafe)
        internal
        returns (LocalAdapter adapter)
    {
        CommonInput memory input = CommonInput({
            centrifugeId: localCentrifugeId,
            adminSafe: adminSafe,
            messageGasLimit: uint128(GAS),
            maxBatchSize: uint128(GAS) * 100,
            isTests: true
        });

        deploy.deployFull(input, address(deploy));

        adapter = new LocalAdapter(localCentrifugeId, deploy.multiAdapter(), address(deploy));
        _wire(deploy, remoteCentrifugeId, adapter);

        deploy.removeFullDeployerAccess(address(deploy));
    }

    function _setSpoke(FullDeployer deploy, uint16 centrifugeId, CSpoke storage s_) internal {
        if (s_.centrifugeId != 0) return; // Already set

        s_.centrifugeId = centrifugeId;
        s_.root = deploy.root();
        s_.guardian = deploy.guardian();
        s_.gateway = deploy.gateway();
        s_.balanceSheet = deploy.balanceSheet();
        s_.spoke = deploy.spoke();
        s_.router = deploy.vaultRouter();
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
}

/// Common and generic flows ready to be used in different tests
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

    function _configureAsset(CSpoke memory s_) internal {
        vm.startPrank(DEPLOYER);
        s_.usdc.mint(INVESTOR_A, USDC_AMOUNT_1);

        vm.startPrank(ANY);
        s_.spoke.registerAsset{value: GAS}(h.centrifugeId, address(s_.usdc), 0);
    }

    function _createPool() internal {
        vm.startPrank(address(h.guardian.safe()));
        h.guardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32("salt"));

        h.hub.createAccount(POOL_A, ASSET_ACCOUNT, true);
        h.hub.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        h.hub.createAccount(POOL_A, LOSS_ACCOUNT, false);
        h.hub.createAccount(POOL_A, GAIN_ACCOUNT, false);

        vm.stopPrank();
    }

    function _configurePool(CSpoke memory s_) internal {
        _configureAsset(s_);

        if (!h.hubRegistry.exists(POOL_A)) {
            _createPool();
        }

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, s_.centrifugeId);
        h.hub.notifyShareClass{value: GAS}(POOL_A, SC_1, s_.centrifugeId, s_.redemptionRestrictionsHook.toBytes32());

        h.hub.initializeHolding(
            POOL_A, SC_1, s_.usdcId, h.valuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );
        h.hub.setRequestManager{value: GAS}(POOL_A, SC_1, s_.usdcId, address(s.asyncRequestManager).toBytes32());
        h.hub.updateBalanceSheetManager{value: GAS}(
            s_.centrifugeId, POOL_A, address(s.asyncRequestManager).toBytes32(), true
        );
        h.hub.updateBalanceSheetManager{value: GAS}(s_.centrifugeId, POOL_A, address(s.syncManager).toBytes32(), true);
        h.hub.updateBalanceSheetManager{value: GAS}(s_.centrifugeId, POOL_A, BSM.toBytes32(), true);
        h.hub.setSnapshotHook(POOL_A, h.snapshotHook);

        vm.startPrank(BSM);
        s_.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);

        vm.stopPrank();
    }

    function _configurePool(bool sameChain) internal {
        _setSpoke(sameChain);
        _configurePool(s);

        /// We subsidize the hub using the local spoke deployment
        if (s.centrifugeId != h.centrifugeId) {
            vm.startPrank(FM);
            h.hub.notifyPool{value: GAS}(POOL_A, h.centrifugeId);

            vm.startPrank(BSM);
            h.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
        }
    }

    function _configurePrices(D18 assetPrice, D18 sharePrice) internal {
        h.valuation.setPrice(s.usdcId, USD_ID, assetPrice);

        vm.startPrank(FM);
        h.hub.updateSharePrice(POOL_A, SC_1, sharePrice);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, s.centrifugeId);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, s.usdcId);

        currentAssetPrice = assetPrice;
        currentSharePrice = sharePrice;
    }

    function _testAsyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _configurePool(sameChain);
        nonZeroPrices ? _configurePrices(ASSET_PRICE, SHARE_PRICE) : _configurePrices(ZERO_PRICE, ZERO_PRICE);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS
        );

        IAsyncVault vault = IAsyncVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, s.usdcId)));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);

        vm.startPrank(FM);
        uint32 depositEpochId = h.hub.shareClassManager().nowDepositEpoch(SC_1, s.usdcId);
        h.hub.approveDeposits{value: GAS}(POOL_A, SC_1, s.usdcId, depositEpochId, USDC_AMOUNT_1);

        vm.startPrank(FM);
        uint32 issueEpochId = h.hub.shareClassManager().nowIssueEpoch(SC_1, s.usdcId);
        (, D18 sharePrice) = h.shareClassManager.metrics(SC_1);
        h.hub.issueShares{value: GAS}(POOL_A, SC_1, s.usdcId, issueEpochId, sharePrice);

        vm.startPrank(ANY);
        uint32 maxClaims = h.shareClassManager.maxDepositClaims(SC_1, INVESTOR_A.toBytes32(), s.usdcId);
        h.hub.notifyDeposit{value: GAS}(POOL_A, SC_1, s.usdcId, INVESTOR_A.toBytes32(), maxClaims);

        vm.startPrank(INVESTOR_A);
        vault.mint(vault.maxMint(INVESTOR_A), INVESTOR_A);

        // CHECKS
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "expected shares");
    }

    function _testSyncDeposit(bool sameChain, bool nonZeroPrices) public {
        _configurePool(sameChain);
        nonZeroPrices ? _configurePrices(ASSET_PRICE, SHARE_PRICE) : _configurePrices(ZERO_PRICE, ZERO_PRICE);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, s.syncDepositVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS
        );
        h.hub.updateContract{value: GAS}(
            POOL_A,
            SC_1,
            s.centrifugeId,
            address(s.syncManager).toBytes32(),
            _updateContractSyncDepositMaxReserveMsg(s.usdcId, type(uint128).max),
            EXTRA_GAS
        );

        IBaseVault vault = IBaseVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, s.usdcId)));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vault.deposit(USDC_AMOUNT_1, INVESTOR_A);

        // CHECKS
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), assetToShare(USDC_AMOUNT_1), "expected shares");
    }

    function _testAsyncRedeem(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) internal {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, true) : _testSyncDeposit(sameChain, true);
        nonZeroPrices ? _configurePrices(ASSET_PRICE, SHARE_PRICE) : _configurePrices(ZERO_PRICE, ZERO_PRICE);

        vm.startPrank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS
        );

        IAsyncRedeemVault vault =
            IAsyncRedeemVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, s.usdcId)));

        vm.startPrank(INVESTOR_A);
        uint128 shares = uint128(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A));
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);

        vm.startPrank(FM);
        uint32 redeemEpochId = h.shareClassManager.nowRedeemEpoch(SC_1, s.usdcId);
        h.hub.approveRedeems(POOL_A, SC_1, s.usdcId, redeemEpochId, shares);

        vm.startPrank(FM);
        uint32 revokeEpochId = h.shareClassManager.nowRevokeEpoch(SC_1, s.usdcId);
        (, D18 sharePrice) = h.shareClassManager.metrics(SC_1);
        h.hub.revokeShares{value: GAS}(POOL_A, SC_1, s.usdcId, revokeEpochId, sharePrice);

        vm.startPrank(ANY);
        uint32 maxClaims = h.shareClassManager.maxRedeemClaims(SC_1, INVESTOR_A.toBytes32(), s.usdcId);
        h.hub.notifyRedeem{value: GAS}(POOL_A, SC_1, s.usdcId, INVESTOR_A.toBytes32(), maxClaims);

        vm.startPrank(INVESTOR_A);
        vault.withdraw(vault.maxWithdraw(INVESTOR_A), INVESTOR_A, INVESTOR_A);

        // CHECKS
        assertEq(s.usdc.balanceOf(INVESTOR_A), shareToAsset(shares), "expected assets");
    }

    function _testAsyncRedeemCancel(bool sameChain, bool afterAsyncDeposit, bool nonZeroPrices) public {
        (afterAsyncDeposit) ? _testAsyncDeposit(sameChain, true) : _testSyncDeposit(sameChain, true);
        uint128 expectedShares = assetToShare(USDC_AMOUNT_1);

        nonZeroPrices ? _configurePrices(ASSET_PRICE, SHARE_PRICE) : _configurePrices(ZERO_PRICE, ZERO_PRICE);

        vm.startPrank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A), EXTRA_GAS
        );

        IAsyncRedeemVault vault =
            IAsyncRedeemVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, s.usdcId)));

        vm.startPrank(INVESTOR_A);
        uint128 shares = uint128(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A));
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);
        vault.cancelRedeemRequest(PLACEHOLDER, INVESTOR_A);
        vault.claimCancelRedeemRequest(PLACEHOLDER, INVESTOR_A, INVESTOR_A);

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

        // CHECKS
        (uint128 amount, uint128 value,,) = h.holdings.holding(POOL_A, SC_1, s.usdcId);
        assertEq(amount, 0, "expected amount");
        assertEq(value, assetToPool(0), "expected value");

        assertEq(h.snapshotHook.synced(POOL_A, SC_1, s.centrifugeId), 2, "expected snapshots");

        checkAccountValue(ASSET_ACCOUNT, assetToPool(0), true);
        checkAccountValue(EQUITY_ACCOUNT, assetToPool(0), true);
    }
}

contract EndToEndUseCases is EndToEndFlows {
    using CastLib for *;
    using MathLib for *;

    /// forge-config: default.isolate = true
    function testConfigureAsset(bool sameChain) public {
        _setSpoke(sameChain);
        _configureAsset(s);

        assertEq(h.hubRegistry.decimals(s.usdcId), 6, "expected decimals");
    }

    /// forge-config: default.isolate = true
    function testConfigurePool(bool sameChain) public {
        _setSpoke(sameChain);
        _configurePool(s);
    }

    /// forge-config: default.isolate = true
    function testFundManagement(bool sameChain) public {
        _setSpoke(sameChain);
        _configurePool(s);
        _configurePrices(ASSET_PRICE, SHARE_PRICE);

        vm.startPrank(DEPLOYER);
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
        nonZeroPrices ? _configurePrices(ASSET_PRICE, SHARE_PRICE) : _configurePrices(ZERO_PRICE, ZERO_PRICE);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink, EXTRA_GAS
        );

        IAsyncVault vault = IAsyncVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, s.usdcId)));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vault.cancelDepositRequest(PLACEHOLDER, INVESTOR_A);
        vault.claimCancelDepositRequest(PLACEHOLDER, INVESTOR_A, INVESTOR_A);

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
}
