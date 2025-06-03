// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {ERC20} from "src/misc/ERC20.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IRecoverable} from "src/misc/interfaces/IRecoverable.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {AssetId, newAssetId} from "src/common/types/AssetId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {AccountId} from "src/common/types/AccountId.sol";
import {ISafe} from "src/common/interfaces/IGuardian.sol";
import {Guardian} from "src/common/Guardian.sol";
import {Root} from "src/common/Root.sol";
import {Gateway} from "src/common/Gateway.sol";
import {MessageLib, VaultUpdateKind} from "src/common/libraries/MessageLib.sol";

import {UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {Hub} from "src/hub/Hub.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

import {VaultRouter} from "src/vaults/VaultRouter.sol";
import {Spoke} from "src/spoke/Spoke.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {AsyncRequestManager} from "src/vaults/AsyncRequestManager.sol";
import {SyncRequestManager} from "src/vaults/SyncRequestManager.sol";
import {IBaseRequestManager} from "src/vaults/interfaces/IBaseRequestManager.sol";
import {IAsyncVault} from "src/vaults/interfaces/IAsyncVault.sol";
import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {AsyncVaultFactory} from "src/vaults/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/vaults/factories/SyncDepositVaultFactory.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVault.sol";
import {IAsyncRedeemVault} from "src/vaults/interfaces/IAsyncVault.sol";

import {FullDeployer, HubDeployer, SpokeDeployer} from "script/FullDeployer.s.sol";
import {CommonDeployer, MESSAGE_COST_ENV} from "script/CommonDeployer.s.sol";

import {LocalAdapter} from "test/integration/adapters/LocalAdapter.sol";

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
    using CastLib for *;

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
        bytes32 asyncVaultFactory;
        bytes32 syncDepositVaultFactory;
        AsyncRequestManager asyncRequestManager;
        SyncRequestManager syncRequestManager;
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

    uint128 constant INVESTOR_A_USDC_AMOUNT = 1_000_000e6; // Measured in USDC: 1M of USDC

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

    D18 immutable IDENTITY_PRICE = d18(1, 1);
    D18 immutable TEN_PERCENT = d18(1, 10);

    function setUp() public virtual {
        vm.setEnv(MESSAGE_COST_ENV, vm.toString(GAS));

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

        // Initialize default values
        USD_ID = deployA.USD_ID();
        POOL_A = h.hubRegistry.poolId(CENTRIFUGE_ID_A, 1);
        SC_1 = h.shareClassManager.previewNextShareClassId(POOL_A);

        vm.label(address(adapterAToB), "AdapterAToB");
        vm.label(address(adapterBToA), "AdapterBToA");
        vm.label(address(h.hub), "Hub");
    }

    function _deployChain(FullDeployer deploy, uint16 localCentrifugeId, uint16 remoteCentrifugeId, ISafe safeAdmin)
        internal
        returns (LocalAdapter adapter)
    {
        deploy.deployFull(localCentrifugeId, safeAdmin, address(deploy), true);

        adapter = new LocalAdapter(localCentrifugeId, deploy.multiAdapter(), address(deploy));
        deploy.wire(remoteCentrifugeId, adapter, address(deploy));

        // TODO(later): Re-enable if wire is moved to Guardian
        //             (ref: https://github.com/centrifuge/protocol-v3/pull/415#discussion_r2121671364)
        // deploy.removeFullDeployerAccess(address(deploy));
    }

    function _setSpoke(FullDeployer deploy, uint16 centrifugeId, CSpoke storage spoke) internal {
        if (spoke.centrifugeId != 0) return; // Already set

        spoke.centrifugeId = centrifugeId;
        spoke.root = deploy.root();
        spoke.guardian = deploy.guardian();
        spoke.gateway = deploy.gateway();
        spoke.balanceSheet = deploy.balanceSheet();
        spoke.spoke = deploy.spoke();
        spoke.router = deploy.vaultRouter();
        spoke.fullRestrictionsHook = deploy.fullRestrictionsHook();
        spoke.redemptionRestrictionsHook = deploy.redemptionRestrictionsHook();
        spoke.asyncVaultFactory = address(deploy.asyncVaultFactory()).toBytes32();
        spoke.syncDepositVaultFactory = address(deploy.syncDepositVaultFactory()).toBytes32();
        spoke.asyncRequestManager = deploy.asyncRequestManager();
        spoke.syncRequestManager = deploy.syncRequestManager();
        spoke.usdc = new ERC20(6);
        spoke.usdcId = newAssetId(centrifugeId, 1);

        // Initialize default values
        spoke.usdc.file("name", "USD Coin");
        spoke.usdc.file("symbol", "USDC");
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
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    function _updateRestrictionMemberMsg(address addr) internal pure returns (bytes memory) {
        return UpdateRestrictionMessageLib.UpdateRestrictionMember({
            user: addr.toBytes32(),
            validUntil: type(uint64).max
        }).serialize();
    }

    function _configureAsset(CSpoke memory spoke) internal {
        spoke.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        spoke.spoke.registerAsset{value: GAS}(h.centrifugeId, address(spoke.usdc), 0);

        assertEq(h.hubRegistry.decimals(spoke.usdcId), 6, "expected decimals");
    }

    function _createPool() internal {
        vm.startPrank(address(h.guardian.safe()));
        h.guardian.createPool(POOL_A, FM, USD_ID);
        vm.stopPrank();

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32("salt"));

        h.hub.createAccount(POOL_A, ASSET_ACCOUNT, true);
        h.hub.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        h.hub.createAccount(POOL_A, LOSS_ACCOUNT, false);
        h.hub.createAccount(POOL_A, GAIN_ACCOUNT, false);

        vm.stopPrank();
    }

    function _configurePool(CSpoke memory spoke) internal {
        _configureAsset(spoke);

        if (!h.hubRegistry.exists(POOL_A)) {
            _createPool();
        }

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, spoke.centrifugeId);
        h.hub.notifyShareClass{value: GAS}(
            POOL_A, SC_1, spoke.centrifugeId, spoke.redemptionRestrictionsHook.toBytes32()
        );

        h.hub.initializeHolding(
            POOL_A, SC_1, spoke.usdcId, h.identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );
        h.hub.updateBalanceSheetManager{value: GAS}(spoke.centrifugeId, POOL_A, BSM.toBytes32(), true);

        h.hub.updateSharePrice(POOL_A, SC_1, IDENTITY_PRICE);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, spoke.centrifugeId);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, spoke.usdcId);
        vm.stopPrank();

        vm.startPrank(BSM);
        spoke.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
        vm.stopPrank();
    }
}

contract EndToEndUseCases is EndToEndUtils {
    using CastLib for *;

    /// forge-config: default.isolate = true
    function testConfigureAsset(bool sameChain) public {
        _setSpoke(sameChain);
        _configureAsset(s);
    }

    /// forge-config: default.isolate = true
    function testConfigurePool(bool sameChain) public {
        _setSpoke(sameChain);
        _configurePool(s);
    }

    /// forge-config: default.isolate = true
    function testAsyncDeposit(bool sameChain) public {
        _setSpoke(sameChain);
        _configurePool(s);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(POOL_A, SC_1, s.usdcId, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink);

        IAsyncVault vault = IAsyncVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, s.usdcId)));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), INVESTOR_A_USDC_AMOUNT);
        vault.requestDeposit(INVESTOR_A_USDC_AMOUNT, INVESTOR_A, INVESTOR_A);

        vm.startPrank(FM);
        uint32 depositEpochId = h.hub.shareClassManager().nowDepositEpoch(SC_1, s.usdcId);
        h.hub.approveDeposits{value: GAS}(POOL_A, SC_1, s.usdcId, depositEpochId, INVESTOR_A_USDC_AMOUNT);

        vm.startPrank(FM);
        uint32 issueEpochId = h.hub.shareClassManager().nowIssueEpoch(SC_1, s.usdcId);
        h.hub.issueShares{value: GAS}(POOL_A, SC_1, s.usdcId, issueEpochId, IDENTITY_PRICE);

        vm.startPrank(ANY);
        uint32 maxClaims = h.shareClassManager.maxDepositClaims(SC_1, INVESTOR_A.toBytes32(), s.usdcId);
        h.hub.notifyDeposit{value: GAS}(POOL_A, SC_1, s.usdcId, INVESTOR_A.toBytes32(), maxClaims);

        vm.startPrank(INVESTOR_A);
        vault.mint(s.asyncRequestManager.maxMint(vault, INVESTOR_A), INVESTOR_A);

        // CHECKS
        uint128 expectedShares = h.identityValuation.getQuote(INVESTOR_A_USDC_AMOUNT, s.usdcId, USD_ID);
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), expectedShares);

        // TODO: Add more checks
        // TODO: Check accounting
    }

    /// forge-config: default.isolate = true
    function testSyncDeposit(bool sameChain) public {
        _setSpoke(sameChain);
        _configurePool(s);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(POOL_A, SC_1, s.usdcId, s.syncDepositVaultFactory, VaultUpdateKind.DeployAndLink);

        IBaseVault vault = IBaseVault(address(s.syncRequestManager.vaultByAssetId(POOL_A, SC_1, s.usdcId)));

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), INVESTOR_A_USDC_AMOUNT);
        vault.deposit(INVESTOR_A_USDC_AMOUNT, INVESTOR_A);

        // CHECKS
        uint128 expectedShares = h.identityValuation.getQuote(INVESTOR_A_USDC_AMOUNT, s.usdcId, USD_ID);
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), expectedShares);

        // TODO: Add more checks
        // TODO: Check accounting
    }

    /// forge-config: default.isolate = true
    function testFundManagement(bool sameChain) public {
        testAsyncDeposit(sameChain);

        vm.startPrank(BSM);
        s.balanceSheet.withdraw(POOL_A, SC_1, address(s.usdc), 0, BSM, INVESTOR_A_USDC_AMOUNT);

        uint128 increment = TEN_PERCENT.mulUint128(INVESTOR_A_USDC_AMOUNT, MathLib.Rounding.Down);

        vm.startPrank(DEPLOYER);
        s.usdc.mint(BSM, increment);

        vm.startPrank(BSM);
        s.usdc.approve(address(s.balanceSheet), INVESTOR_A_USDC_AMOUNT + increment);
        s.balanceSheet.deposit(POOL_A, SC_1, address(s.usdc), 0, INVESTOR_A_USDC_AMOUNT + increment);

        // CHECKS
        // TODO: Check holdings in the Hub
    }

    /// forge-config: default.isolate = true
    function testAsyncRedeem(bool sameChain, bool afterAsyncDeposit) public {
        if (afterAsyncDeposit) {
            testAsyncDeposit(sameChain);
        } else {
            testSyncDeposit(sameChain);
        }

        vm.startPrank(FM);
        h.hub.updateRestriction{value: GAS}(POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(INVESTOR_A));

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
        h.hub.revokeShares{value: GAS}(POOL_A, SC_1, s.usdcId, revokeEpochId, IDENTITY_PRICE);

        vm.startPrank(ANY);
        uint32 maxClaims = h.shareClassManager.maxRedeemClaims(SC_1, INVESTOR_A.toBytes32(), s.usdcId);
        h.hub.notifyRedeem{value: GAS}(POOL_A, SC_1, s.usdcId, INVESTOR_A.toBytes32(), maxClaims);

        vm.startPrank(INVESTOR_A);
        vault.withdraw(INVESTOR_A_USDC_AMOUNT, INVESTOR_A, INVESTOR_A);

        // CHECKS
        assertEq(s.usdc.balanceOf(INVESTOR_A), INVESTOR_A_USDC_AMOUNT);

        // TODO: Add more checks
        // TODO: Check accounting
    }
}
