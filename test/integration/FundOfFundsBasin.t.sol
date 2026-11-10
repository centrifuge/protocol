// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {D18, d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {ManagerKind, VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {BasinLiquidityRoute} from "../../src/vaults/liquidity/BasinLiquidityRoute.sol";
import {VaultLiquidityRoute} from "../../src/vaults/liquidity/VaultLiquidityRoute.sol";
import {IVaultLiquidityRoute} from "../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";
import {IAsyncVault, IVaultErrors, IVaultEvents, VaultPlugins} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {IBasinLiquidityRoute, IGroveBasinLike} from "../../src/vaults/liquidity/interfaces/IBasinLiquidityRoute.sol";
import {
    IInstantPolicy,
    ILiquidityRoute,
    IReserveInstantPolicy
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {USD_ID} from "../../src/deployment/Currencies.sol";
import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev Stands in for the Grove basin with a real token balance. What it advertises and what it can
///      pay are set separately, so a test can make a quote the venue then fails to honour.
contract ERC20Basin is IGroveBasinLike {
    ERC20 public immutable asset;
    address public immutable liquidityProvider;
    uint256 public advertised;

    constructor(ERC20 asset_, address liquidityProvider_) {
        asset = asset_;
        liquidityProvider = liquidityProvider_;
    }

    function advertise(uint256 amount) external {
        advertised = amount;
    }

    function previewWithdraw(address, uint256 max) external view returns (uint256, uint256) {
        uint256 assets = advertised < max ? advertised : max;
        return (assets, assets);
    }

    function withdraw(address, address receiver, uint256 max) external returns (uint256 paid) {
        uint256 balance = asset.balanceOf(address(this));
        paid = balance < max ? balance : max;
        asset.transfer(receiver, paid);
    }
}

/// @dev The two fund-of-funds topologies end to end, on the real spoke, escrows, share tokens and vaults.
///
///      Composed, the basin backs jTRSY and the top vault redeems jTRSY:
///
///        FoF Vault.withdraw -> VaultLiquidityRoute -> jTRSY Vault.withdraw -> BasinLiquidityRoute
///                                                                         -> the basin
///
///      Direct, the basin backs the top vault itself and jTRSY is never touched:
///
///        FoF Vault.withdraw -> BasinLiquidityRoute -> the basin
///
///      `POOL_A` is jTRSY: a USDC vault whose escrow is fully deployed. The top pool holds jTRSY shares
///      as its only asset, so an exit from it is paid out of a venue it holds no position in. Both top
///      vaults sit on the same share class, so one investor can exit through either.
/// forge-config: default.isolate = true
contract FundOfFundsBasinTest is EndToEndFlows {
    using CastLib for *;

    uint128 constant DEPOSIT = 1_000e6;
    uint128 constant VENUE = 1_000e6;
    uint128 constant LINE = 600e6;

    address immutable LP = makeAddr("liquidityProvider");

    PoolId topPool;
    ShareClassId topSc;

    ERC20Basin basin;
    BasinLiquidityRoute basinRoute;
    VaultLiquidityRoute vaultRoute;

    IAsyncVault jtrsyVault;
    IAsyncVault topVault;
    IAsyncVault directVault;
    IShareToken jtrsy;
    IShareToken fof;

    /// @dev Called by each test rather than from `setUp`, which the inherited flows share.
    function _setUpChain() internal {
        _configurePool(true);
        _configurePrices(d18(1, 1), d18(1, 1));
        vm.startPrank(FM);
        _setHook(s, address(s.freezeOnlyHook));
        vm.stopPrank();

        // The basin route is per venue, so it is deployed against one rather than by the protocol launch
        basin = new ERC20Basin(s.usdc, LP);
        basinRoute = new BasinLiquidityRoute(
            basin, s.spoke, address(deployA.envoy()), deployA.accountingToken(), address(deployA.root())
        );
        vaultRoute = deployA.vaultLiquidityRoute();

        jtrsyVault = _deployVault(POOL_A, SC_1, address(basinRoute));
        jtrsy = IShareToken(jtrsyVault.share());
        _openInstantLane(POOL_A, jtrsyVault);
        _enableBooking(POOL_A);
        _setLine(POOL_A, jtrsyVault, LINE);

        _createTopPool();
        topVault = _deployVault(topPool, topSc, address(vaultRoute));
        fof = IShareToken(topVault.share());
        _openInstantLane(topPool, topVault);

        address[] memory routes = new address[](1);
        routes[0] = address(jtrsyVault);
        _managerCall(
            POOL_A,
            address(vaultRoute),
            abi.encode(
                IVaultLiquidityRoute.ConfigKind.Consent, address(jtrsyVault), abi.encode(address(topVault), true)
            )
        );
        _managerCall(
            topPool,
            address(vaultRoute),
            abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, address(topVault), abi.encode(routes))
        );

        directVault = _deployVault(topPool, topSc, address(basinRoute));
        _openInstantLane(topPool, directVault);
        _enableBooking(topPool);
        _setLine(topPool, directVault, LINE);

        _investThroughTheTopPool();

        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(address(basin), VENUE);
        vm.stopPrank();
        basin.advertise(VENUE);
    }

    //----------------------------------------------------------------------------------------------
    // Setup
    //----------------------------------------------------------------------------------------------

    /// @dev A second pool on the same spoke, denominated in USD, with USDC as its vault asset and the
    ///      jTRSY share token registered as an asset it can hold.
    function _createTopPool() internal {
        topPool = h.hubRegistry.poolId(CENTRIFUGE_ID_A, 2);
        topSc = h.shareClassManager.previewNextShareClassId(topPool);

        vm.startPrank(address(h.protocolGuardian.safe()));
        h.opsGuardian.createPool(topPool, FM, USD_ID);
        vm.stopPrank();

        vm.startPrank(FM);
        h.hub.addShareClass(topPool, "Fund of Funds", "FOF", bytes32(bytes8(topPool.raw())));
        h.hub.createAccount(topPool, ASSET_ACCOUNT, true);
        h.hub.createAccount(topPool, EQUITY_ACCOUNT, false);
        h.hub.createAccount(topPool, GAIN_ACCOUNT, false);
        h.hub.createAccount(topPool, LOSS_ACCOUNT, true);
        h.hub.notifyPool{value: GAS}(topPool, s.centrifugeId, REFUND);
        h.hub.notifyShareClass{value: GAS}(
            topPool, topSc, s.centrifugeId, address(s.shareTokenRegistrar).toBytes32(), "", 0, REFUND
        );
        h.hub
            .initializeHolding(
                topPool,
                topSc,
                s.usdcId,
                h.identityValuation,
                _holdingAccounts(ASSET_ACCOUNT, EQUITY_ACCOUNT, GAIN_ACCOUNT, LOSS_ACCOUNT)
            );
        h.hub.updateManager{value: GAS}(topPool, s.centrifugeId, ManagerKind.Spoke, BSM.toBytes32(), true, REFUND);
        // The route releases the jTRSY position from the top pool's escrow, as a balance-sheet manager.
        h.hub.updateManager{value: GAS}(
            topPool, s.centrifugeId, ManagerKind.Spoke, address(vaultRoute).toBytes32(), true, REFUND
        );

        h.hub.updateSharePrice(topPool, topSc, d18(1, 1), uint64(block.timestamp));
        h.hub.notifySharePrice{value: GAS}(topPool, topSc, s.centrifugeId, REFUND);
        h.hub.notifyAssetPrice{value: GAS}(topPool, topSc, s.usdcId, REFUND);
        vm.stopPrank();

        vm.startPrank(ANY);
        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(jtrsy), 0, ANY);
        vm.stopPrank();
    }

    function _deployVault(PoolId poolId, ShareClassId scId, address route) internal returns (IAsyncVault vault) {
        VaultPlugins memory plugins = _defaultPlugins();
        plugins.instantPolicy = IInstantPolicy(address(s.reserveInstantPolicy));
        plugins.liquidityRoute = ILiquidityRoute(route);
        bytes memory payload = abi.encode(plugins, uint64(0), uint256(0));
        vault = IAsyncVault(s.vaultFactory.deploy(poolId, scId, address(s.usdc), 0, payload));

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            poolId,
            scId,
            s.usdcId,
            address(s.vaultFactory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            payload,
            EXTRA_GAS,
            REFUND
        );
        assertTrue(s.spokeRegistry.isLinked(address(vault)), "vault not linked");

        h.hub.updateManager{value: GAS}(
            poolId, s.centrifugeId, ManagerKind.Spoke, address(vault).toBytes32(), true, REFUND
        );
        vm.stopPrank();
    }

    function _openInstantLane(PoolId poolId, IAsyncVault vault) internal {
        bytes memory terms = abi.encode(address(0), uint16(0), uint16(0), true, false, false, 10 * DEPOSIT);
        _managerCall(
            poolId,
            address(s.reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(vault), terms)
        );
    }

    /// @dev The route books each draw as the pool's liability: it deposits liability accounting tokens
    ///      into the escrow, so it is a balance-sheet manager and a minter of the pool, and the token is
    ///      a spoke asset.
    function _enableBooking(PoolId poolId) internal {
        vm.startPrank(FM);
        h.hub.updateManager{value: GAS}(
            poolId, s.centrifugeId, ManagerKind.Spoke, address(basinRoute).toBytes32(), true, REFUND
        );
        vm.stopPrank();
        _managerCall(poolId, address(deployA.accountingToken()), abi.encode(address(basinRoute).toBytes32(), true));

        uint256 liabilityId = deployA.accountingToken().toTokenId(poolId, address(s.usdc), true);
        if (s.spokeRegistry.assetToId(address(deployA.accountingToken()), liabilityId).isNull()) {
            vm.prank(ANY);
            s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(deployA.accountingToken()), liabilityId, ANY);
        }
    }

    /// @dev Both sides of a vault's credit line: the pool's limit through the Envoy, the venue's
    ///      credit from its liquidity provider.
    function _setLine(PoolId poolId, IAsyncVault vault, uint128 line) internal {
        _managerCall(poolId, address(basinRoute), abi.encode(address(vault), line));
        vm.prank(LP);
        basinRoute.setCredit(address(vault), line);
    }

    function _managerCall(PoolId poolId, address target, bytes memory payload) internal {
        vm.startPrank(FM);
        h.hub.managerCall(poolId, s.centrifugeId, target.toBytes32(), payload, EXTRA_GAS, 0, REFUND);
        vm.stopPrank();
    }

    /// @dev The investor buys into the top pool; its manager puts the USDC into jTRSY and parks the
    ///      shares in the top escrow; jTRSY's manager deploys its own USDC. Afterwards neither escrow
    ///      holds any USDC, and the top pool's whole position is jTRSY.
    function _investThroughTheTopPool() internal {
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(topVault), DEPOSIT);
        topVault.deposit(DEPOSIT, INVESTOR_A);
        vm.stopPrank();

        vm.startPrank(BSM);
        s.spoke.withdraw(topPool, topSc, address(s.usdc), 0, BSM, DEPOSIT);
        s.usdc.approve(address(jtrsyVault), DEPOSIT);
        uint256 shares = jtrsyVault.deposit(DEPOSIT, BSM);
        jtrsy.approve(address(s.spoke), shares);
        s.spoke.deposit(topPool, topSc, address(jtrsy), 0, uint128(shares));

        s.spoke.withdraw(POOL_A, SC_1, address(s.usdc), 0, BSM, DEPOSIT);
        vm.stopPrank();

        assertEq(s.usdc.balanceOf(topVault.escrow()), 0, "the top escrow holds no USDC");
        assertEq(s.usdc.balanceOf(jtrsyVault.escrow()), 0, "and neither does jTRSY's");
        assertEq(jtrsy.balanceOf(topVault.escrow()), shares, "the top pool holds jTRSY");
    }

    //----------------------------------------------------------------------------------------------
    // The chain
    //----------------------------------------------------------------------------------------------

    /// @dev Capacity composes down the chain: the top vault's instant capacity is what the route can
    ///      raise from jTRSY, which is what jTRSY can raise from the basin, which is bounded by the
    ///      credit line rather than by the venue's whole balance.
    function testCapacityComposesDownTheChain() public {
        _setUpChain();

        assertEq(basinRoute.available(address(jtrsyVault)), LINE, "the basin quotes the line, not the venue");
        assertEq(jtrsyVault.withdrawCapacity(address(vaultRoute)), LINE, "jTRSY's capacity is the basin's");
        assertEq(vaultRoute.available(address(topVault)), LINE, "the route's is jTRSY's");
        assertEq(topVault.maxWithdraw(INVESTOR_A), LINE, "and the top vault's is the route's");

        _setLine(POOL_A, jtrsyVault, 2 * VENUE);
        assertEq(topVault.maxWithdraw(INVESTOR_A), VENUE, "a wider line exposes the venue itself");

        basin.advertise(0);
        assertEq(topVault.maxWithdraw(INVESTOR_A), 0, "and an empty venue closes the top vault's lane");
    }

    /// @dev One call at the top, paid out of the basin two hops down. The debt lands on the vault that
    ///      drew, jTRSY, and comes off its line, which the top vault then reports as its own capacity.
    function testInstantExitIsPaidFromTheBasinTwoHopsDown() public {
        _setUpChain();

        uint128 exit = 250e6;
        address topEscrow = topVault.escrow();
        uint256 jtrsySupply = jtrsy.totalSupply();

        vm.prank(INVESTOR_A);
        uint256 burnt = topVault.withdraw(exit, INVESTOR_A);

        assertEq(s.usdc.balanceOf(INVESTOR_A), USDC_AMOUNT_1 - DEPOSIT + exit, "the investor was paid");
        assertEq(burnt, 250e18, "against their top-level shares at par");
        assertEq(fof.balanceOf(INVESTOR_A), 750e18, "which were burnt");
        assertEq(s.usdc.balanceOf(address(basin)), VENUE - exit, "out of the basin");

        assertEq(s.usdc.balanceOf(topEscrow), 0, "nothing rests in the top escrow");
        assertEq(s.usdc.balanceOf(jtrsyVault.escrow()), 0, "or in jTRSY's");
        assertEq(jtrsy.balanceOf(topEscrow), 750e18, "the top pool's jTRSY position shrank by the exit");
        assertEq(jtrsy.totalSupply(), jtrsySupply - 250e18, "and those jTRSY shares were burnt");
        assertEq(jtrsy.balanceOf(address(vaultRoute)), 0, "none rest on the route");

        assertEq(basinRoute.receivable(address(jtrsyVault)), exit, "jTRSY owes the venue the draw");
        assertEq(basinRoute.receivable(address(topVault)), 0, "the top vault owes it nothing");
        assertEq(topVault.maxWithdraw(INVESTOR_A), LINE - exit, "the rest of the line is the top capacity");

        // jTRSY's manager settles the draw, which restores the line.
        vm.startPrank(BSM);
        s.usdc.approve(address(basinRoute), exit);
        basinRoute.repay(address(jtrsyVault), exit);
        vm.stopPrank();

        assertEq(s.usdc.balanceOf(LP), exit, "repaid to the liquidity provider");
        assertEq(basinRoute.receivable(address(jtrsyVault)), 0, "clearing the debt");
        assertEq(topVault.maxWithdraw(INVESTOR_A), LINE, "and reopening the line");
    }

    /// @dev When the route's capacity is the pool's whole position in the underlying, not the underlying's
    ///      liquidity, an exit at the top's `maxRedeem` or `maxWithdraw` still goes through: the route draws the
    ///      position to its last share, at a share price and an exit fee that round.
    /// forge-config: default.fuzz.runs = 64
    function testFuzzAnExitAtTheMaximumDrawsThePositionToItsLastShare(uint64 priceSeed, uint16 feeBps, bool byAssets)
        public
    {
        _setUpChain();
        // The venue and the line exceed the position, so the position bounds the route
        vm.startPrank(ERC20_DEPLOYER);
        s.usdc.mint(address(basin), 10 * VENUE);
        vm.stopPrank();
        basin.advertise(11 * VENUE);
        _setLine(POOL_A, jtrsyVault, 11 * VENUE);

        // jTRSY's shares are worth a little less than they were bought at, at a price that rounds
        uint128 price = uint128(bound(priceSeed, 5e17, 1e18 - 1));
        _configurePrices(d18(1, 1), d18(price));
        feeBps = uint16(bound(feeBps, 0, 100));
        bytes memory terms = abi.encode(address(0), uint16(0), feeBps, true, false, false, 10 * DEPOSIT);
        _managerCall(
            POOL_A,
            address(s.reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(jtrsyVault), terms)
        );

        uint256 held = jtrsy.balanceOf(topVault.escrow());
        assertLt(
            vaultRoute.available(address(topVault)),
            jtrsyVault.withdrawCapacity(address(vaultRoute)),
            "the position binds"
        );
        assertGt(held, 0);

        if (byAssets) {
            uint256 max = topVault.maxWithdraw(INVESTOR_A);
            vm.prank(INVESTOR_A);
            topVault.withdraw(max, INVESTOR_A);
        } else {
            uint256 max = topVault.maxRedeem(INVESTOR_A);
            vm.prank(INVESTOR_A);
            topVault.redeem(max, INVESTOR_A);
        }
        // What is left of the position is worth less than one more unit of the asset
        uint256 left = jtrsy.balanceOf(topVault.escrow());
        assertLe(jtrsyVault.previewRedeem(left), 1, "the position is drawn to its last share");
        assertLt(left, held, "and something was drawn");
        assertEq(topVault.maxRedeem(INVESTOR_A), 0, "the route has nothing left to offer");
    }

    /// @dev An exit past the line fails at the top rather than drawing past it at the bottom.
    function testAnExitPastTheLineFailsAtTheTop() public {
        _setUpChain();

        vm.prank(INVESTOR_A);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        topVault.withdraw(LINE + 1, INVESTOR_A);
    }

    /// @dev A venue that quotes liquidity it then does not pay fails the whole chain: the basin route
    ///      refuses the short draw, and that refusal unwinds jTRSY's exit and the top vault's with it.
    ///      Nothing moves and nothing is recorded as owed.
    function testADryBasinRevertsTheWholeChain() public {
        _setUpChain();

        vm.prank(address(basin));
        s.usdc.transfer(makeAddr("elsewhere"), VENUE);
        assertEq(topVault.maxWithdraw(INVESTOR_A), LINE, "the stale quote still reaches the top");

        uint256 topJtrsy = jtrsy.balanceOf(topVault.escrow());

        vm.prank(INVESTOR_A);
        vm.expectRevert(IBasinLiquidityRoute.InsufficientLiquidity.selector);
        topVault.withdraw(250e6, INVESTOR_A);

        assertEq(fof.balanceOf(INVESTOR_A), DEPOSIT * 1e12, "the investor keeps their shares");
        assertEq(jtrsy.balanceOf(topVault.escrow()), topJtrsy, "the top pool keeps its jTRSY");
        assertEq(basinRoute.receivable(address(jtrsyVault)), 0, "and no debt is recorded");
    }

    /// @dev The vault route releases the top pool's own jTRSY through the spoke, so it acts as that
    ///      pool's balance-sheet manager. Without the role the composed exit cannot be paid, so the
    ///      route advertises nothing and the top vault's capacity drops to its own escrow's.
    function testTheVaultRouteActsAsABalanceSheetManager() public {
        _setUpChain();

        vm.startPrank(FM);
        h.hub.updateManager{value: GAS}(
            topPool, s.centrifugeId, ManagerKind.Spoke, address(vaultRoute).toBytes32(), false, REFUND
        );
        vm.stopPrank();

        assertEq(vaultRoute.available(address(topVault)), 0, "the route cannot release the position");
        assertEq(topVault.maxWithdraw(INVESTOR_A), 0, "so the top vault reports only its empty escrow");

        vm.prank(INVESTOR_A);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        topVault.withdraw(250e6, INVESTOR_A);
    }

    /// @dev An instant exit paid partly by the route reports the draw beside the fee, which is what ties the exit to the route's own `VaultRouteProvided` event.
    function testInstantFeesReportTheRouteDraw() public {
        _setUpChain();
        address feeRecipient = makeAddr("feeRecipient");
        bytes memory terms = abi.encode(feeRecipient, uint16(0), uint16(100), true, false, false, 10 * DEPOSIT);
        _managerCall(
            topPool,
            address(s.reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(topVault), terms)
        );

        // 100 shares at par gross 100 USDC: 1 to the fee recipient, 99 paid out. The escrow holds no USDC,
        // so the route supplies all that leaves it: the payout and the fee.
        (D18 ppa, D18 pps,) = topVault.oracle().prices(topPool, topSc, topVault.assetId());
        vm.expectEmit(address(topVault));
        emit IVaultEvents.InstantFees(INVESTOR_A, INVESTOR_A, false, 100e18, 1e6, feeRecipient, 0, 100e6, ppa, pps);
        vm.prank(INVESTOR_A);
        assertEq(topVault.redeem(100e18, INVESTOR_A), 99e6);
    }

    //----------------------------------------------------------------------------------------------
    // The underlying is another pool's
    //----------------------------------------------------------------------------------------------

    /// @dev jTRSY's pool pausing its own oracle, or simply letting its prices go stale, makes every
    ///      jTRSY quote revert. That takes the route's line to zero, but must not take down the top
    ///      vault's instant lane: an exit its own escrow can pay still goes through.
    function testAnUnderlyingPoolsInvalidPriceLeavesTheTopVaultsOwnLiquidity() public {
        _setUpChain();

        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, 500e6);
        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), 500e6);
        s.spoke.deposit(topPool, topSc, address(s.usdc), 0, 500e6);
        vm.stopPrank();

        _managerCall(POOL_A, address(s.spokeOracle), abi.encode(true));

        assertEq(vaultRoute.available(address(topVault)), 0, "the route has nothing it can quote");
        assertEq(topVault.maxWithdraw(INVESTOR_A), 500e6, "the top vault still offers its own escrow");

        vm.prank(INVESTOR_A);
        topVault.withdraw(100e6, INVESTOR_A);
        assertEq(s.usdc.balanceOf(INVESTOR_A), USDC_AMOUNT_1 - DEPOSIT + 100e6, "paid from the top escrow");
    }

    /// @dev A route the underlying share token has frozen cannot take delivery of the position, so the
    ///      line it would otherwise report is one every draw on it reverts. It reports none instead.
    function testAFrozenRouteReportsNoCapacity() public {
        _setUpChain();

        vm.startPrank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionFreezeMsg(address(vaultRoute)), EXTRA_GAS, REFUND
        );
        vm.stopPrank();

        assertEq(vaultRoute.available(address(topVault)), 0, "the route cannot hold jTRSY");
        assertEq(topVault.maxWithdraw(INVESTOR_A), 0, "so the top vault offers nothing it cannot pay");
    }

    /// @dev The route never requests and makes no one its operator, so only a sponsor of jTRSY's pool could credit
    ///      it a position, and the 2-argument exit it draws through stays instant. A holder who is no sponsor is
    ///      refused.
    function testAHolderCannotPushARedeemOntoTheRoute() public {
        _setUpChain();
        address griefer = makeAddr("griefer");
        uint256 capacity = topVault.maxWithdraw(INVESTOR_A);

        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(griefer, 1e6);
        vm.startPrank(griefer);
        s.usdc.approve(address(jtrsyVault), 1e6);
        jtrsyVault.deposit(1e6, griefer);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        jtrsyVault.requestRedeem(1e12, address(vaultRoute), griefer);
        vm.stopPrank();

        // The griefer's deposit is jTRSY escrow liquidity now, on top of what the route could draw before.
        assertGe(topVault.maxWithdraw(INVESTOR_A), capacity, "the route's lane is untouched");
    }

    //----------------------------------------------------------------------------------------------
    // Direct
    //----------------------------------------------------------------------------------------------

    /// @dev One hop: the basin pays the top vault's escrow and the debt is the top pool's. jTRSY is
    ///      never called, so it could as well be a vault that offers no instant exit at all.
    function testDirectExitIsPaidFromTheBasinOneHop() public {
        _setUpChain();

        uint128 exit = 250e6;
        address topEscrow = directVault.escrow();
        uint256 jtrsySupply = jtrsy.totalSupply();
        uint256 topJtrsy = jtrsy.balanceOf(topEscrow);

        assertEq(directVault.maxWithdraw(INVESTOR_A), LINE, "the direct vault's capacity is its own line");

        vm.prank(INVESTOR_A);
        uint256 burnt = directVault.withdraw(exit, INVESTOR_A);

        assertEq(s.usdc.balanceOf(INVESTOR_A), USDC_AMOUNT_1 - DEPOSIT + exit, "the investor was paid");
        assertEq(burnt, 250e18, "against their top-level shares at par");
        assertEq(s.usdc.balanceOf(address(basin)), VENUE - exit, "out of the basin");
        assertEq(s.usdc.balanceOf(topEscrow), 0, "nothing rests in the top escrow");

        assertEq(jtrsy.balanceOf(topEscrow), topJtrsy, "the top pool keeps its whole jTRSY position");
        assertEq(jtrsy.totalSupply(), jtrsySupply, "and no jTRSY is redeemed");

        assertEq(basinRoute.receivable(address(directVault)), exit, "the top pool owes the venue the draw");
        assertEq(basinRoute.receivable(address(jtrsyVault)), 0, "jTRSY owes it nothing");
        assertEq(directVault.maxWithdraw(INVESTOR_A), LINE - exit, "the rest of the line is the capacity");

        // The top pool's manager settles the draw, typically once a jTRSY redemption has paid out.
        vm.startPrank(BSM);
        s.usdc.approve(address(basinRoute), exit);
        basinRoute.repay(address(directVault), exit);
        vm.stopPrank();

        assertEq(s.usdc.balanceOf(LP), exit, "repaid to the liquidity provider");
        assertEq(directVault.maxWithdraw(INVESTOR_A), LINE, "reopening the line");
    }

    /// @dev The same exit through each topology, from the same state. The direct path skips a second
    ///      vault's pricing, share pull and burn, and the escrow movements around them.
    function testDirectExitCostsLessThanTheComposedOne() public {
        _setUpChain();
        uint256 snapshot = vm.snapshotState();

        vm.prank(INVESTOR_A);
        topVault.withdraw(250e6, INVESTOR_A);
        uint256 composed = vm.lastCallGas().gasTotalUsed;

        vm.revertToState(snapshot);

        vm.prank(INVESTOR_A);
        directVault.withdraw(250e6, INVESTOR_A);
        uint256 direct = vm.lastCallGas().gasTotalUsed;

        emit log_named_uint("composed exit gas", composed);
        emit log_named_uint("direct exit gas", direct);
        assertLt(direct, composed, "one hop is cheaper than two");
    }
}
