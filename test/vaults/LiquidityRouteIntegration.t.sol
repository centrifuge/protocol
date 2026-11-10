// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {ReentrancyProtection} from "../../src/misc/ReentrancyProtection.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IEscrow} from "../../src/core/spoke/interfaces/IEscrow.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {
    IVaultRequestManager,
    IVaultDepositCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {
    IAsyncVault,
    IVaultErrors,
    IVaultEvents,
    VaultConfig,
    VaultPlugins
} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {
    IInstantPolicy,
    IRequestPolicy,
    ILiquidityRoute,
    ISettlementObserver
} from "../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import "forge-std/Test.sol";

import {IRoleHook} from "../../src/token/interfaces/IRoleHook.sol";
import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";

/// @dev A liquidity route wired into a live vault, recording what the vault offers it in each
///      direction: `provide` on the redeem side (liquidity pulled in to cover an exit), `forward` on
///      the deposit side (idle assets offered out for allocation). Both no-op the actual movement —
///      this exercises the vault's own call sequence, not a venue.
contract RecordingRoute is ILiquidityRoute {
    uint128 public lastProvide;
    uint128 public lastForward;
    uint128 internal _available;
    uint128 internal _withheld;
    MockERC20 internal _asset;
    address internal _escrow;

    function setAvailable(uint128 a) external {
        _available = a;
    }

    /// @dev Where `provide` delivers to, and how much short of the request it falls.
    function setDelivery(MockERC20 asset, address escrow, uint128 withheld) external {
        _asset = asset;
        _escrow = escrow;
        _withheld = withheld;
    }

    function provide(address, uint128 assets) external {
        lastProvide = assets;
        if (address(_asset) != address(0)) _asset.mint(_escrow, assets - _withheld);
    }

    function forward(address, uint128 assets) external {
        lastForward = assets;
    }

    function available(address) external view returns (uint128) {
        return _available;
    }
}

/// @dev A venue that re-enters the vault from inside `provide` — the call `_executeInstantRedeem` makes to
///      cover an escrow shortfall, before the share pull, the burn and the payout. The realistic
///      shape is not a hostile route but a legitimate one whose swap has an attacker-influenceable
///      callback.
contract ReenteringRoute is ILiquidityRoute {
    IAsyncVault public vault;
    address public receiver;
    uint128 public reenterShares;
    uint128 public provideCalls;
    uint128 internal _available;

    function arm(IAsyncVault vault_, address receiver_, uint128 shares) external {
        vault = vault_;
        receiver = receiver_;
        reenterShares = shares;
    }

    function setAvailable(uint128 a) external {
        _available = a;
    }

    function provide(address, uint128) external {
        provideCalls++;
        if (reenterShares != 0) {
            uint128 shares = reenterShares;
            reenterShares = 0; // re-enter exactly once
            vault.redeem(shares, receiver);
        }
    }

    function forward(address, uint128) external {}

    function available(address) external view returns (uint128) {
        return _available;
    }
}

/// @dev A route whose `available` reverts, as a third-party venue's quote can.
contract RevertingQuoteRoute is ILiquidityRoute {
    function provide(address, uint128) external {}

    function forward(address, uint128) external {}

    function available(address) external pure returns (uint128) {
        revert("quote down");
    }
}

/// @dev A route that pays nothing but, from inside `provide`, makes a deposit request on a sibling
///      vault of the same pool: the sibling's assets land in the shared escrow, exactly the
///      shortfall the drawing vault is waiting for.
contract SiblingDepositingRoute is ILiquidityRoute {
    IAsyncVault public sibling;
    MockERC20 public asset;
    address public escrow;

    constructor(IAsyncVault sibling_, MockERC20 asset_, address escrow_) {
        sibling = sibling_;
        asset = asset_;
        escrow = escrow_;
    }

    function provide(address, uint128 assets) external {
        sibling.requestDeposit(assets, address(this), address(this));
        // The mock token moves no balances, so the deposit's arrival in the escrow is minted there.
        asset.mint(escrow, assets);
    }

    function forward(address, uint128) external {}

    function available(address) external pure returns (uint128) {
        return type(uint128).max;
    }
}

/// @dev A route whose `forward` reverts.
contract FailingRoute is ILiquidityRoute {
    function provide(address, uint128) external {}

    function forward(address, uint128) external pure {
        revert("route down");
    }

    function available(address) external pure returns (uint128) {
        return 0;
    }
}

/// @dev The Vault <-> ILiquidityRoute contract, both directions, end to end: deposits offer their
///      freshly-idle assets to the route through `forward` (instant issuance and async approval
///      alike), and an instant redeem short of escrow pulls the shortfall back through `provide`. The
///      route's accounting is mocked at the spoke boundary, as the rest of the vault suite does; what
///      is real here is the vault's own call sequence to the route.
contract LiquidityRouteIntegrationTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address actionHook = address(new IsContract());
    address router = address(new IsContract());
    address oracle = address(new IsContract());
    address instantPolicy = address(new IsContract());
    address escrow = address(new AmpleEscrow());

    MockERC20 asset = new MockERC20(6);
    MockShareToken share = new MockShareToken(18);
    PerRequestPolicy requestPolicy = new PerRequestPolicy(true);
    RecordingRoute route = new RecordingRoute();

    Vault vault;
    IAsyncVault v;

    address controller = makeAddr("controller");
    address receiver = makeAddr("receiver");

    function setUp() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));

        vault = new Vault(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            IShareToken(address(share)),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(spoke),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    instantPolicy: IInstantPolicy(instantPolicy),
                    requestPolicy: IRequestPolicy(address(requestPolicy)),
                    liquidityRoute: ILiquidityRoute(address(route)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
        v = IAsyncVault(address(vault));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), true))
        );
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.requestManager.selector), abi.encode(router));
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, true));
        share.setHook(actionHook);
        vm.mockCall(
            actionHook, abi.encodeWithSelector(IRoleHook.onRoles.selector), abi.encode(IRoleHook.onRoles.selector)
        );
        vm.mockCall(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), abi.encode(true));
        vm.mockCall(
            actionHook,
            abi.encodeWithSelector(IRoleHook.maxAllowed.selector),
            abi.encode(type(uint256).max, type(uint256).max)
        );
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector), "");
        vm.mockCall(router, abi.encodeWithSelector(IVaultRequestManager.sendRedeemRequest.selector), "");

        bytes4[9] memory voids = [
            ISpoke.noteDeposit.selector,
            ISpoke.reserve.selector,
            ISpoke.unreserve.selector,
            ISpoke.issue.selector,
            ISpoke.revoke.selector,
            ISpoke.withdraw.selector,
            ISpoke.withdrawReserved.selector,
            ISpoke.withdrawShares.selector,
            ISpoke.transferSharesFrom.selector
        ];
        for (uint256 i; i < voids.length; i++) {
            vm.mockCall(spoke, abi.encodeWithSelector(voids[i]), "");
        }

        // Instant policy: uncapped, no fees.
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector),
            abi.encode(uint128(type(uint128).max))
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(type(uint128).max))
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(0), address(0))
        );
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(0), address(0))
        );
    }

    /// @dev An instant deposit offers exactly the assets that reached the escrow to the route, so a
    ///      forwarding route allocates them rather than leaving them idle. This is auto-allocation on
    ///      the instant lane.
    function testInstantDepositForwardsToTheRoute() public {
        vm.prank(controller);
        v.deposit(1_000e6, receiver);

        assertEq(route.lastForward(), 1_000e6, "the deposited assets were offered to the route");
        assertEq(route.lastProvide(), 0, "a deposit pulls nothing in");
    }

    /// @dev And the async lane: approving a pending deposit releases its assets into the holding and
    ///      offers exactly that released amount to the route. Auto-allocation on the async lane.
    function testApproveDepositForwardsTheReleasedAssets() public {
        vm.prank(controller);
        uint256 requestId = v.requestDeposit(1_000e6, controller, controller);
        assertEq(route.lastForward(), 0, "requesting reserves assets, it does not release them");

        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(uint96(requestId), 1_000e6);

        assertEq(route.lastForward(), 1_000e6, "approval offered the released assets to the route");
    }

    /// @dev Approving more than is still reserved releases only what is there, and the route is offered that
    ///      released amount, not the amount the manager asked to approve.
    function testApproveDepositOffersOnlyWhatWasReleased() public {
        vm.prank(controller);
        uint256 requestId = v.requestDeposit(1_000e6, controller, controller);
        vm.mockCall(escrow, abi.encodeWithSelector(IEscrow.reservedBy.selector), abi.encode(uint128(1_000e6)));

        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(uint96(requestId), 1_500e6);

        assertEq(route.lastForward(), 1_000e6, "the clamped release, not the requested approval");
    }

    /// @dev The offer to the route is logged with the clamped release, not the callback's amount.
    function testApproveDepositLogsTheClampedOffer() public {
        vm.prank(controller);
        uint256 requestId = v.requestDeposit(1_000e6, controller, controller);
        vm.mockCall(escrow, abi.encodeWithSelector(IEscrow.reservedBy.selector), abi.encode(uint128(1_000e6)));

        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.ForwardedToRoute(address(route), requestId, 1_000e6);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(uint96(requestId), 1_500e6);
    }

    function testAnInstantDepositLogsItsOfferToTheRoute() public {
        vm.expectEmit(true, true, false, true, address(vault));
        emit IVaultEvents.ForwardedToRoute(address(route), 0, 1_000e6);
        vm.prank(controller);
        v.deposit(1_000e6, receiver);
    }

    /// @dev Escrow holds less than the payout, and the route reports enough headroom, so the instant
    ///      redeem draws the shortfall back through `provide` — the exact shortfall, and nothing on
    ///      the forward leg.
    function testInstantRedeemSourcesTheEscrowShortfallThroughTheRoute() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(100e6)));
        route.setAvailable(1_000_000e6);
        route.setDelivery(asset, address(vault), 0);

        vm.prank(controller);
        v.redeem(1_000e18, receiver); // 1000 shares at par -> 1000e6 assets

        assertEq(route.lastProvide(), 900e6, "exactly the escrow shortfall was sourced");
        assertEq(route.lastForward(), 0, "a redeem offers nothing out");
    }

    /// @dev A manager may reserve past the escrow's total, ahead of arrival. What the route brings in meets that first,
    ///      so the capacity it adds is net of it, and the draw covers it: 100 held against 300 reserved leaves 200 to
    ///      cover, so a route offering 500 adds 300, and paying out 300 draws 500.
    function testRouteLiquidityIsNetOfWhatIsReservedBeyondTheEscrow() public {
        vm.mockCall(escrow, abi.encodeWithSelector(AmpleEscrow.holding.selector), abi.encode(100e6, 300e6));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(0)));
        route.setAvailable(500e6);
        route.setDelivery(asset, address(vault), 0);

        assertEq(v.withdrawCapacity(controller), 300e6, "the route adds what it offers less the over-reservation");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.redeem(301e18, receiver);

        vm.prank(controller);
        v.redeem(300e18, receiver);
        assertEq(route.lastProvide(), 500e6, "the draw covers the payout and the over-reservation");
    }

    /// @dev When the route offers no more than the over-reservation, it adds nothing, and the lane reports none
    ///      rather than a capacity the reservation would absorb.
    function testARouteThatOffersNoMoreThanTheOverReservationAddsNothing() public {
        vm.mockCall(escrow, abi.encodeWithSelector(AmpleEscrow.holding.selector), abi.encode(100e6, 300e6));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(0)));
        route.setAvailable(200e6);

        assertEq(v.withdrawCapacity(controller), 0, "all of it would be absorbed by the reservation");
    }

    /// @dev The shortfall is noted into the holding as deposited, so it has to have arrived: a route
    ///      that delivers less would otherwise be paid out of whatever else the escrow holds.
    function testARouteThatUnderDeliversRevertsTheExit() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(100e6)));
        route.setAvailable(1_000_000e6);
        route.setDelivery(asset, address(vault), 1);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InsufficientLiquidity.selector);
        v.redeem(1_000e18, receiver);
    }

    /// @dev The redeem path hands `_executeInstantRedeem` an escrow balance read before the policy hooks ran,
    ///      and calls the route before the share pull, the burn and the payout. Left unguarded, a venue
    ///      that re-enters funds a second exit from the same snapshot: two 1_000e6 payouts against an
    ///      escrow holding 100e6, and the route drawn twice for the same shortfall. That is also what
    ///      defeats any instant-policy bound derived from observed liquidity rather than from a counter
    ///      the policy increments itself, which is what a rate limiter is.
    function testAReenteringRouteCannotFundASecondExit() public {
        ReenteringRoute hostile = new ReenteringRoute();
        Vault reentrant = _vaultWithRoute(address(hostile));

        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(100e6)));
        hostile.setAvailable(1_000_000e6);
        hostile.arm(IAsyncVault(address(reentrant)), receiver, 1_000e18);

        vm.prank(controller);
        vm.expectRevert(ReentrancyProtection.Reentrancy.selector);
        IAsyncVault(address(reentrant)).redeem(1_000e18, receiver);
    }

    /// @dev The route is the pool's choice, so a quote that reverts takes the instant redeem views and
    ///      exits down with it whenever the policy cap exceeds the escrow.
    function testARevertingRouteQuoteBlocksTheRedeemLane() public {
        Vault guarded = _vaultWithRoute(address(new RevertingQuoteRoute()));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(5_000e6)));

        vm.expectRevert("quote down");
        IAsyncVault(address(guarded)).maxRedeem(controller);

        vm.prank(controller);
        vm.expectRevert("quote down");
        IAsyncVault(address(guarded)).redeem(1_000e18, receiver);
    }

    /// @dev The route is asked only for liquidity beyond the escrow's: under a policy cap the escrow
    ///      covers, it is not consulted at all.
    function testTheRouteIsNotAskedWhenTheEscrowCoversTheCap() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(5_000e6)));
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector),
            abi.encode(uint128(2_000e6))
        );

        vm.expectCall(address(route), abi.encodeCall(ILiquidityRoute.available, (address(v))), 0);
        assertEq(v.maxRedeem(controller), 2_000e18);
        vm.prank(controller);
        v.redeem(2_000e18, receiver);
    }

    /// @dev When the escrow already covers the payout, neither leg of the route is touched.
    function testAFullyLiquidRedeemNeitherProvidesNorForwards() public {
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(1_000_000e6)));
        route.setAvailable(1_000_000e6);

        vm.prank(controller);
        v.redeem(1_000e18, receiver);

        assertEq(route.lastProvide(), 0, "a covered payout sources nothing");
        assertEq(route.lastForward(), 0, "and offers nothing out");
    }

    /// @dev The forward leg is called plainly, so a route that reverts blocks the approval callback
    ///      until the pool fixes or replaces it.
    function testARevertingForwardBlocksApproval() public {
        FailingRoute failing = new FailingRoute();
        IAsyncVault stalled = IAsyncVault(address(_vaultWithRoute(address(failing))));

        vm.prank(controller);
        uint256 requestId = stalled.requestDeposit(1_000e6, controller, controller);

        vm.prank(router);
        vm.expectRevert("route down");
        IVaultDepositCallbacks(address(stalled)).approveDeposits(uint96(requestId), 1_000e6);
    }

    /// @dev The escrow is shared by every vault of the pool, so an inflow there is not proof of
    ///      delivery: a sibling's deposit, made from inside `provide`, would be noted twice and pay the
    ///      exit out of assets reserved for that request. Delivery is measured at the drawing vault.
    function testASiblingDepositIntoTheEscrowIsNotDelivery() public {
        IAsyncVault sibling = IAsyncVault(address(_vaultWithRoute(address(0))));
        Vault drawing = _vaultWithRoute(address(new SiblingDepositingRoute(sibling, asset, escrow)));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(100e6)));

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InsufficientLiquidity.selector);
        IAsyncVault(address(drawing)).redeem(1_000e18, receiver);
    }

    function _vaultWithRoute(address route_) internal returns (Vault) {
        return new Vault(
            POOL,
            SC,
            address(asset),
            ASSET_ID,
            IShareToken(address(share)),
            VaultConfig({
                foldHorizon: 0,
                spoke: ISpoke(spoke),
                spokeRegistry: ISpokeRegistry(spokeRegistry),
                plugins: VaultPlugins({
                    oracle: IVaultOracle(oracle),
                    instantPolicy: IInstantPolicy(instantPolicy),
                    requestPolicy: IRequestPolicy(address(requestPolicy)),
                    liquidityRoute: ILiquidityRoute(route_),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
    }
}
