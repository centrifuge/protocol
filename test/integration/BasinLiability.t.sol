// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {ERC20Basin} from "./FundOfFundsBasin.t.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {D18, d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {AssetId} from "../../src/core/types/AssetId.sol";
import {ISnapshotHook} from "../../src/core/hub/interfaces/ISnapshotHook.sol";
import {IHubRequestManager} from "../../src/core/hub/interfaces/IHubRequestManager.sol";
import {ManagerKind, VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {NAVManager} from "../../src/hooks/accounting/NAVManager.sol";
import {INAVManager} from "../../src/hooks/accounting/interfaces/INAVManager.sol";
import {SimplePriceManager} from "../../src/hooks/accounting/SimplePriceManager.sol";

import {AccountingToken} from "../../src/managers/spoke/AccountingToken.sol";

import {IAsyncVault, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {BasinLiquidityRoute} from "../../src/vaults/liquidity/BasinLiquidityRoute.sol";
import {
    IInstantPolicy,
    ILiquidityRoute,
    IReserveInstantPolicy
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev A Basin draw on a pool whose price is published by on-chain NAV automation (`NAVManager` feeding
///      `SimplePriceManager`). The draw lands cash the pool owes, so the route books the debt as the
///      pool's liability in the same transaction, and the price the hub publishes is the same before
///      the draw, after it, and after the repayment.
///
///      The pool is fully deployed: its 100 USDC of subscriptions sit in a T-bill position, so its escrow
///      holds no USDC and a 10-share instant exit is paid entirely out of the basin. Without the
///      liability the hub would see 100 of assets over 90 shares and publish 1.111.
/// forge-config: default.isolate = true
contract BasinLiabilityTest is EndToEndFlows {
    using CastLib for *;

    uint128 constant DEPOSIT = 100e6;
    uint128 constant EXIT = 10e6;
    uint128 constant LINE = 50e6;

    address immutable LP = makeAddr("liquidityProvider");

    NAVManager navManager;
    SimplePriceManager simplePriceManager;
    AccountingToken accountingToken;
    ERC20Basin basin;
    BasinLiquidityRoute route;
    IAsyncVault vault;
    IShareToken share;

    ERC20 tbill;
    AssetId tbillId;
    AssetId liabilityId;
    uint256 liabilityTokenId;

    function _setUpPool() internal {
        _setSpoke(true);
        navManager = deployA.navManager();
        simplePriceManager = deployA.simplePriceManager();
        accountingToken = deployA.accountingToken();

        _createPool();
        _configureAsset(s);
        vm.stopPrank();
        tbill = new ERC20(6);
        vm.startPrank(ANY);
        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(tbill), 0, ANY);
        vm.stopPrank();
        tbillId = s.spokeRegistry.assetToId(address(tbill), 0);

        vm.startPrank(FM);
        h.hub.notifyPool{value: GAS}(POOL_A, s.centrifugeId, REFUND);
        h.hub.notifyShareClass{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, address(s.shareTokenRegistrar).toBytes32(), "", 0, REFUND
        );
        _setHook(s, address(s.freezeOnlyHook));
        h.hub.updateManager{value: GAS}(POOL_A, s.centrifugeId, ManagerKind.Spoke, BSM.toBytes32(), true, REFUND);
        h.hub.setRequestManager{value: GAS}(
            POOL_A,
            s.centrifugeId,
            IHubRequestManager(address(h.orderBook)),
            address(s.vaultRequestRouter).toBytes32(),
            REFUND
        );
        vm.stopPrank();

        basin = new ERC20Basin(s.usdc, LP);
        route =
            new BasinLiquidityRoute(basin, s.spoke, address(deployA.envoy()), accountingToken, address(deployA.root()));

        // The liability token is a spoke asset like any other, registered permissionlessly
        liabilityTokenId = accountingToken.toTokenId(POOL_A, address(s.usdc), true);
        vm.startPrank(ANY);
        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(accountingToken), liabilityTokenId, ANY);
        vm.stopPrank();
        liabilityId = s.spokeRegistry.assetToId(address(accountingToken), liabilityTokenId);

        _configureNav();
        _enableBooking();

        vm.prank(FM);
        h.hub.updateSharePrice(POOL_A, SC_1, d18(1, 1), uint64(block.timestamp));
        _notifyPrices();

        _deployBasinVault();
        _managerCall(address(route), abi.encode(address(vault), LINE));
        vm.prank(LP);
        route.setCredit(address(vault), LINE);
        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(address(basin), LINE);
        basin.advertise(LINE);
    }

    /// @dev The hub side: NAV automation over the pool's USDC and T-bills, and the USDC liability token
    ///      as a liability holding, so NAV = assets - liabilities.
    function _configureNav() internal {
        vm.startPrank(FM);
        h.hub.setSnapshotHook(POOL_A, ISnapshotHook(address(navManager)));
        h.hub.updateHubManager(POOL_A, address(navManager), true);
        h.hub.updateHubManager(POOL_A, address(simplePriceManager), true);
        vm.stopPrank();

        _navCall(abi.encode(uint8(INAVManager.ManagerCall.SetNavHook), address(simplePriceManager)));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.SetDefaultValuation), address(h.identityValuation)));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeNetwork), s.centrifugeId));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), SC_1, s.usdcId));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeHolding), SC_1, tbillId));
        _navCall(abi.encode(uint8(INAVManager.ManagerCall.InitializeLiability), SC_1, liabilityId));
    }

    /// @dev The spoke side: the route is a balance-sheet manager of the pool and a minter of its
    ///      accounting tokens.
    function _enableBooking() internal {
        vm.startPrank(FM);
        h.hub.updateManager{value: GAS}(
            POOL_A, s.centrifugeId, ManagerKind.Spoke, address(route).toBytes32(), true, REFUND
        );
        vm.stopPrank();
        _managerCall(address(accountingToken), abi.encode(address(route).toBytes32(), true));
    }

    function _deployBasinVault() internal {
        VaultPlugins memory plugins = _defaultPlugins();
        plugins.instantPolicy = IInstantPolicy(address(s.reserveInstantPolicy));
        plugins.liquidityRoute = ILiquidityRoute(address(route));
        bytes memory payload = abi.encode(plugins, uint64(0), uint256(0));

        // Deployed locally first; the hub's message only registers and links it.
        vault = IAsyncVault(payable(s.vaultFactory.deploy(POOL_A, SC_1, address(s.usdc), 0, payload)));
        share = IShareToken(address(s.spokeRegistry.shareToken(POOL_A, SC_1)));

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
        h.hub.updateManager{value: GAS}(
            POOL_A, s.centrifugeId, ManagerKind.Spoke, address(vault).toBytes32(), true, REFUND
        );
        vm.stopPrank();

        bytes memory terms = abi.encode(address(0), uint16(0), uint16(0), true, false, false, 10 * DEPOSIT);
        _managerCall(
            address(s.reserveInstantPolicy), abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(vault), terms)
        );
    }

    function _navCall(bytes memory payload) internal {
        _managerCall(address(navManager), payload);
    }

    function _managerCall(address target, bytes memory payload) internal {
        vm.startPrank(FM);
        h.hub.managerCall(POOL_A, s.centrifugeId, target.toBytes32(), payload, EXTRA_GAS, 0, REFUND);
        vm.stopPrank();
    }

    function _notifyPrices() internal {
        vm.startPrank(FM);
        h.hub.notifySharePrice{value: GAS}(POOL_A, SC_1, s.centrifugeId, REFUND);
        h.hub.notifyAssetPrice{value: GAS}(POOL_A, SC_1, s.usdcId, REFUND);
        vm.stopPrank();
    }

    function _submit(AssetId assetId) internal {
        vm.startPrank(BSM);
        s.spoke.submitQueuedAssets{value: GAS}(POOL_A, SC_1, assetId, EXTRA_GAS, REFUND);
        vm.stopPrank();
    }

    function _submitShares() internal {
        vm.startPrank(BSM);
        s.spoke.submitQueuedShares{value: GAS}(POOL_A, SC_1, EXTRA_GAS, REFUND);
        vm.stopPrank();
    }

    function _price() internal view returns (D18 price) {
        (price,) = h.shareClassManager.pricePoolPerShare(POOL_A, SC_1);
    }

    function _nav() internal view returns (int128) {
        return navManager.netAssetValue(POOL_A, s.centrifugeId);
    }

    /// @dev The investor subscribes 100 USDC at par, and the manager moves it all into T-bills.
    function _investAndDeploy() internal {
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT, INVESTOR_A);
        vm.stopPrank();

        vm.prank(ERC20_DEPLOYER);
        tbill.mint(BSM, DEPOSIT);
        vm.startPrank(BSM);
        s.spoke.withdraw(POOL_A, SC_1, address(s.usdc), 0, BSM, DEPOSIT);
        tbill.approve(address(s.spoke), DEPOSIT);
        s.spoke.deposit(POOL_A, SC_1, address(tbill), 0, DEPOSIT);
        vm.stopPrank();

        _submit(s.usdcId);
        _submit(tbillId);
        _submitShares();

        assertEq(s.usdc.balanceOf(vault.escrow()), 0, "the escrow holds no USDC");
        assertEq(_nav(), 100e18, "100 of T-bills");
        assertEq(h.shareClassManager.issuance(POOL_A, SC_1, s.centrifugeId), 100e18, "over 100 shares");
        assertEq(_price().raw(), 1e18, "at par");
    }

    //----------------------------------------------------------------------------------------------
    // Tests
    //----------------------------------------------------------------------------------------------

    /// @dev The published price is exact through the draw and the repayment.
    function testADrawLeavesThePublishedPriceUnchanged() public {
        _setUpPool();
        _investAndDeploy();

        // A 10-share exit, paid entirely from the basin
        vm.prank(INVESTOR_A);
        vault.withdraw(EXIT, INVESTOR_A);
        assertEq(route.receivable(address(vault)), EXIT, "the pool owes the venue the draw");
        assertEq(
            s.spoke.availableBalanceOf(POOL_A, SC_1, address(accountingToken), liabilityTokenId),
            EXIT,
            "and the debt sits in the escrow beside the cash it paid for"
        );

        // The hub publishes once every leg of the draw is in: the cash in and out, the debt, the burn.
        (, uint64 publishedAt) = h.shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        skip(1 hours);
        _submit(s.usdcId);
        _submit(liabilityId);
        (, uint64 partialAt) = h.shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        assertEq(partialAt, publishedAt, "no price is published from a partial picture");
        _submitShares();
        (, uint64 syncedAt) = h.shareClassManager.pricePoolPerShare(POOL_A, SC_1);
        assertEq(syncedAt, block.timestamp, "the complete one is published");

        (uint128 owed,,) = h.holdings.holding(POOL_A, SC_1, liabilityId);
        assertEq(owed, EXIT, "the hub holds the debt");
        assertEq(_nav(), 90e18, "NAV is the T-bills less what is owed");
        assertEq(h.shareClassManager.issuance(POOL_A, SC_1, s.centrifugeId), 90e18, "over the 90 shares left");
        assertEq(_price().raw(), 1e18, "so the price stays at par, not 100/90");

        // The manager sells 10 of T-bills and repays the venue with the proceeds.
        vm.startPrank(BSM);
        s.spoke.withdraw(POOL_A, SC_1, address(tbill), 0, BSM, EXIT);
        vm.stopPrank();
        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, EXIT);
        vm.startPrank(BSM);
        s.usdc.approve(address(route), EXIT);
        route.repay(address(vault), EXIT);
        vm.stopPrank();

        assertEq(route.receivable(address(vault)), 0, "the debt is settled");
        assertEq(s.usdc.balanceOf(LP), EXIT, "with the liquidity provider");
        assertEq(accountingToken.balanceOf(vault.escrow(), liabilityTokenId), 0, "and its token burnt");

        _submit(tbillId);
        _submit(liabilityId);

        (owed,,) = h.holdings.holding(POOL_A, SC_1, liabilityId);
        assertEq(owed, 0, "the hub holds no debt");
        assertEq(_nav(), 90e18, "90 of T-bills");
        assertEq(_price().raw(), 1e18, "and the price is still par");
    }

    /// @dev The line reopens on repayment and the next draw is booked the same way.
    function testTheLineRevolvesWithItsLiability() public {
        _setUpPool();
        _investAndDeploy();

        vm.prank(INVESTOR_A);
        vault.withdraw(LINE, INVESTOR_A);
        assertEq(vault.maxWithdraw(INVESTOR_A), 0, "the line is used up");

        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, LINE);
        vm.startPrank(BSM);
        s.usdc.approve(address(route), LINE);
        route.repay(address(vault), LINE);
        vm.stopPrank();
        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(address(basin), LINE);

        vm.prank(INVESTOR_A);
        vault.withdraw(EXIT, INVESTOR_A);
        assertEq(accountingToken.balanceOf(vault.escrow(), liabilityTokenId), EXIT, "only the open draw is booked");
    }

    /// @dev A pool that has not let the route book the debt gets no Basin capacity, rather than a draw
    ///      that inflates its price.
    function testWithoutBookingTheLineIsClosed() public {
        _setUpPool();
        _investAndDeploy();

        _managerCall(address(accountingToken), abi.encode(address(route).toBytes32(), false));

        assertEq(route.available(address(vault)), 0, "the route offers nothing it cannot book");
        assertEq(vault.maxWithdraw(INVESTOR_A), 0, "and the vault only its empty escrow");
    }
}
