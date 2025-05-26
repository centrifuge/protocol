// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.28;

import "forge-std/Test.sol";

import {ERC20} from "src/misc/ERC20.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {IdentityValuation} from "src/misc/IdentityValuation.sol";
import {D18, d18} from "src/misc/types/D18.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
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

import {Hub} from "src/hub/Hub.sol";
import {HubRegistry} from "src/hub/HubRegistry.sol";
import {Accounting} from "src/hub/Accounting.sol";
import {Holdings} from "src/hub/Holdings.sol";
import {ShareClassManager} from "src/hub/ShareClassManager.sol";
import {IShareClassManager} from "src/hub/interfaces/IShareClassManager.sol";

import {VaultRouter} from "src/spoke/vaults/VaultRouter.sol";
import {Spoke} from "src/spoke/Spoke.sol";
import {BalanceSheet} from "src/spoke/BalanceSheet.sol";
import {AsyncRequestManager} from "src/spoke/vaults/AsyncRequestManager.sol";
import {SyncRequestManager} from "src/spoke/vaults/SyncRequestManager.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IAsyncVault} from "src/spoke/interfaces/vaults/IBaseVaults.sol";
import {SyncDepositVault} from "src/spoke/vaults/SyncDepositVault.sol";
import {AsyncVaultFactory} from "src/spoke/factories/AsyncVaultFactory.sol";
import {SyncDepositVaultFactory} from "src/spoke/factories/SyncDepositVaultFactory.sol";
import {IBaseVault} from "src/spoke/interfaces/vaults/IBaseVaults.sol";

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
///   deployA.hub().notifyPool() // Will fail, given prank is used to retriver the hub.
///
///   2. It increases significatily the amount of calls shown by the debugger.
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
    AssetId USDC_ID;

    FullDeployer deployA = new FullDeployer();
    FullDeployer deployB = new FullDeployer();

    CHub h;
    CSpoke s;

    D18 immutable IDENTITY_PRICE = d18(1, 1);
    D18 immutable TEN_PERCENT = d18(1, 10);

    function setUp() public {
        vm.setEnv(MESSAGE_COST_ENV, vm.toString(GAS));

        LocalAdapter adapterA = _deployChain(deployA, CENTRIFUGE_ID_A, CENTRIFUGE_ID_B, safeAdminA);
        LocalAdapter adapterB = _deployChain(deployB, CENTRIFUGE_ID_B, CENTRIFUGE_ID_A, safeAdminB);

        // We connect both deploys through the adapters
        adapterA.setEndpoint(adapterB);
        adapterB.setEndpoint(adapterA);

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
    }

    function _deployChain(FullDeployer deploy, uint16 localCentrifugeId, uint16 remoteCentrifugeId, ISafe safeAdmin)
        internal
        returns (LocalAdapter adapter)
    {
        deploy.deployFull(localCentrifugeId, safeAdmin, address(deploy), true);

        adapter = new LocalAdapter(localCentrifugeId, deploy.multiAdapter(), address(deploy));
        deploy.wire(remoteCentrifugeId, adapter, address(deploy));

        deploy.removeFullDeployerAccess(address(deploy));
    }

    function _setSpoke(bool sameChain) internal {
        if (s.centrifugeId != 0) return; // Already set

        FullDeployer deploy = (sameChain) ? deployA : deployB;
        uint16 centrifugeId = (sameChain) ? CENTRIFUGE_ID_A : CENTRIFUGE_ID_B;
        s = CSpoke({
            centrifugeId: centrifugeId,
            root: deploy.root(),
            guardian: deploy.guardian(),
            gateway: deploy.gateway(),
            balanceSheet: deploy.balanceSheet(),
            spoke: deploy.spoke(),
            router: deploy.vaultRouter(),
            fullRestrictionsHook: deploy.fullRestrictionsHook(),
            redemptionRestrictionsHook: deploy.redemptionRestrictionsHook(),
            asyncVaultFactory: address(deploy.asyncVaultFactory()).toBytes32(),
            syncDepositVaultFactory: address(deploy.syncDepositVaultFactory()).toBytes32(),
            asyncRequestManager: deploy.asyncRequestManager(),
            syncRequestManager: deploy.syncRequestManager(),
            usdc: new ERC20(6)
        });

        // Initialize default values
        s.usdc.file("name", "USD Coin");
        s.usdc.file("symbol", "USDC");

        USDC_ID = newAssetId(centrifugeId, 1);
    }
}

/// Common and generic actions ready to be used in different tests
contract EndToEndActionsSet is EndToEndDeployment {
    using CastLib for *;

    function asyncDeposit(address investor, uint128 amount) internal {
        IAsyncVault vault = IAsyncVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, USDC_ID)));

        vm.startPrank(investor);
        s.usdc.approve(address(vault), amount);
        vault.requestDeposit(amount, investor, investor);
    }

    function approve(uint128 amount) internal {
        vm.startPrank(FM);
        uint32 depositEpochId = h.hub.shareClassManager().nowDepositEpoch(SC_1, USDC_ID);
        h.hub.approveDeposits{value: GAS}(POOL_A, SC_1, USDC_ID, depositEpochId, amount);
    }

    function issue() internal {
        vm.startPrank(FM);
        uint32 depositEpochId = h.hub.shareClassManager().nowIssueEpoch(SC_1, USDC_ID);
        h.hub.issueShares{value: GAS}(POOL_A, SC_1, USDC_ID, depositEpochId, IDENTITY_PRICE);
    }

    function asyncClaim(address investor) internal {
        vm.startPrank(ANY);
        uint32 maxClaims = h.shareClassManager.maxDepositClaims(SC_1, investor.toBytes32(), USDC_ID);
        h.hub.notifyDeposit{value: GAS}(POOL_A, SC_1, USDC_ID, investor.toBytes32(), maxClaims);

        IAsyncVault vault = IAsyncVault(address(s.asyncRequestManager.vaultByAssetId(POOL_A, SC_1, USDC_ID)));

        vm.startPrank(investor);
        vault.mint(s.asyncRequestManager.maxMint(vault, investor), investor);
    }

    function syncDeposit(address investor, uint128 amount) internal {
        IBaseVault vault = s.syncRequestManager.vaultByAssetId(POOL_A, SC_1, USDC_ID);

        vm.startPrank(investor);
        s.usdc.approve(address(vault), amount);
        vault.deposit(amount, investor);
    }

    function withdraw(uint128 amount) internal {
        vm.startPrank(BSM);
        s.balanceSheet.withdraw(POOL_A, SC_1, address(s.usdc), 0, BSM, amount);
    }

    function setSharePrice(D18 yield) internal {
        vm.startPrank(FM);
        h.hub.updateSharePrice{value: GAS}(POOL_A, SC_1, IDENTITY_PRICE + yield);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, s.centrifugeId);
    }

    function deposit(uint128 amount, uint128 newAmount) internal {
        vm.startPrank(DEPLOYER);
        s.usdc.mint(BSM, newAmount);

        vm.startPrank(BSM);
        s.usdc.approve(address(s.balanceSheet), amount);
        s.balanceSheet.deposit(POOL_A, SC_1, address(s.usdc), 0, amount);
    }

    function updateRestrictionMemberMsg() internal returns (bytes memory) {
        return
            MessageLib.UpdateRestrictionMember({user: INVESTOR_A.toBytes32(), validUntil: type(uint64).max}).serialize();
    }
}

contract EndToEndUseCases is EndToEndActionsSet {
    using CastLib for *;

    /// forge-config: default.isolate = true
    function testConfigureAsset(bool sameChain) public {
        _setSpoke(sameChain);

        s.usdc.mint(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(s.usdc), 0);

        assertEq(h.hubRegistry.decimals(USDC_ID), 6, "expected decimals");
    }

    /// forge-config: default.isolate = true
    function testConfigurePool(bool sameChain) public {
        testConfigureAsset(sameChain);

        vm.startPrank(address(h.guardian.safe()));
        h.guardian.createPool(POOL_A, FM, USD_ID);

        vm.startPrank(FM);
        h.hub.setPoolMetadata(POOL_A, bytes("Testing pool"));
        h.hub.addShareClass(POOL_A, "Tokenized MMF", "MMF", bytes32("salt"));
        h.hub.notifyPool{value: GAS}(POOL_A, s.centrifugeId);
        h.hub.notifyShareClass{value: GAS}(POOL_A, SC_1, s.centrifugeId, s.redemptionRestrictionsHook.toBytes32());

        h.hub.createAccount(POOL_A, ASSET_ACCOUNT, true);
        h.hub.createAccount(POOL_A, EQUITY_ACCOUNT, false);
        h.hub.createAccount(POOL_A, LOSS_ACCOUNT, false);
        h.hub.createAccount(POOL_A, GAIN_ACCOUNT, false);
        h.hub.initializeHolding(
            POOL_A, SC_1, USDC_ID, h.identityValuation, ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT
        );
        h.hub.updateBalanceSheetManager{value: GAS}(s.centrifugeId, POOL_A, BSM.toBytes32(), true);

        h.hub.updateSharePrice(POOL_A, SC_1, IDENTITY_PRICE);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, s.centrifugeId);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, USDC_ID);

        vm.startPrank(BSM);
        s.gateway.subsidizePool{value: DEFAULT_SUBSIDY}(POOL_A);
    }

    /// forge-config: default.isolate = true
    function testAsyncDeposit(bool sameChain) public {
        testConfigurePool(sameChain);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(POOL_A, SC_1, USDC_ID, s.asyncVaultFactory, VaultUpdateKind.DeployAndLink);

        asyncDeposit(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);
        approve(INVESTOR_A_USDC_AMOUNT);
        issue();
        asyncClaim(INVESTOR_A);

        uint256 expectedShares = h.identityValuation.getQuote(INVESTOR_A_USDC_AMOUNT, USDC_ID.addr(), USD_ID.addr());
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), expectedShares);
    }

    /// forge-config: default.isolate = true
    function testSyncDeposit(bool sameChain) public {
        testConfigurePool(sameChain);

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(POOL_A, SC_1, USDC_ID, s.syncDepositVaultFactory, VaultUpdateKind.DeployAndLink);

        syncDeposit(INVESTOR_A, INVESTOR_A_USDC_AMOUNT);

        uint256 expectedShares = h.identityValuation.getQuote(INVESTOR_A_USDC_AMOUNT, USDC_ID.addr(), USD_ID.addr());
        assertEq(s.spoke.shareToken(POOL_A, SC_1).balanceOf(INVESTOR_A), expectedShares);
    }

    /// forge-config: default.isolate = true
    function testFundManagement(bool sameChain) public {
        testAsyncDeposit(sameChain);

        withdraw(INVESTOR_A_USDC_AMOUNT);

        // Emulates a yield
        uint128 increment = TEN_PERCENT.mulUint128(INVESTOR_A_USDC_AMOUNT, MathLib.Rounding.Down);
        deposit(INVESTOR_A_USDC_AMOUNT, increment);
    }

    /// forge-config: default.isolate = true
    function testAsyncRedeem(bool sameChain) public {
        testAsyncDeposit();

        h.hub.updateRestriction(POOL_A, SC_1, s.centrifugeId, updateRestrictionMemberMsg());

        ///
        setSharePrice(IDENTITY_PRICE + TEN_PERCENT);
    }
}
