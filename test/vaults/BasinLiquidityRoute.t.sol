// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IsContract} from "./Vault.t.sol";

import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {VaultDetails, ISpokeRegistry} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {AccountingToken} from "../../src/managers/spoke/AccountingToken.sol";
import {IAccountingToken} from "../../src/managers/spoke/interfaces/IAccountingToken.sol";

import {IVault} from "../../src/vaults/interfaces/IVault.sol";
import {BasinLiquidityRoute} from "../../src/vaults/liquidity/BasinLiquidityRoute.sol";
import {IBasinLiquidityRoute, IGroveBasinLike} from "../../src/vaults/liquidity/interfaces/IBasinLiquidityRoute.sol";

import "forge-std/Test.sol";

contract MockAsset {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "insufficient");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

/// @dev Stands in for the Grove basin: holds a withdrawable balance and pays it out to whoever the
///      route names as receiver.
contract MockBasin {
    MockAsset public asset;
    address public liquidityProvider;
    uint256 public withdrawable;
    uint256 public cap = type(uint256).max;
    bool public overstates;
    bool public broken;

    constructor(MockAsset asset_, address liquidityProvider_) {
        asset = asset_;
        liquidityProvider = liquidityProvider_;
    }

    function setWithdrawable(uint256 amount) external {
        withdrawable = amount;
    }

    /// @dev Lets a test make the basin pay out less than it was asked for.
    function setCap(uint256 cap_) external {
        cap = cap_;
    }

    /// @dev Lets a test make the basin report the full amount while paying out only the cap.
    function setOverstates(bool overstates_) external {
        overstates = overstates_;
    }

    function setBroken(bool broken_) external {
        broken = broken_;
    }

    bool public short;

    /// @dev Answers one word where two are expected.
    function setShort(bool short_) external {
        short = short_;
    }

    function previewWithdraw(address, uint256) external view returns (uint256, uint256) {
        require(!broken, "cannot quote");
        if (short) {
            assembly {
                mstore(0, 1)
                return(0, 0x20)
            }
        }
        return (0, withdrawable);
    }

    function withdraw(address, address receiver, uint256 maxAssetsToWithdraw) external returns (uint256) {
        uint256 paid = maxAssetsToWithdraw < cap ? maxAssetsToWithdraw : cap;
        asset.mint(receiver, paid);
        return overstates ? maxAssetsToWithdraw : paid;
    }
}

/// @dev The liquidity route backs instant exits with third-party funds, so the questions are: who
///      may draw on it and how much, is a draw always paid to the drawing vault, is the debt
///      recorded, and who may settle it.
contract BasinLiquidityRouteTest is Test {
    using CastLib for address;

    PoolId constant POOL = PoolId.wrap(1);
    PoolId constant OTHER_POOL = PoolId.wrap(2);
    uint128 constant UNLIMITED = type(uint128).max;
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));

    address spoke = address(new IsContract());
    address spokeRegistry = address(new IsContract());
    address vault = address(new IsContract());
    address envoy = makeAddr("envoy");
    address escrow = makeAddr("escrow");
    address provider = makeAddr("liquidityProvider");
    address payer = makeAddr("payer");
    address outsider = makeAddr("outsider");

    MockAsset asset = new MockAsset();
    MockBasin basin;
    BasinLiquidityRoute route;
    AccountingToken accountingToken;
    uint256 liabilityId;

    function setUp() public {
        basin = new MockBasin(asset, provider);
        accountingToken = new AccountingToken(envoy);
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.spokeRegistry.selector), abi.encode(spokeRegistry));
        route = new BasinLiquidityRoute(
            IGroveBasinLike(address(basin)), ISpoke(spoke), envoy, accountingToken, makeAddr("root")
        );
        liabilityId = accountingToken.toTokenId(POOL, address(asset), true);

        // The asset drawn comes from the registry.
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, vault),
            abi.encode(VaultDetails(POOL, SC, newAssetId(0, 1), address(asset), uint256(0), true))
        );
        vm.mockCall(vault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(POOL));
        vm.mockCall(vault, abi.encodeWithSelector(IVault.scId.selector), abi.encode(SC));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector), abi.encode(escrow));
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.deposit.selector), "");
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.withdraw.selector), "");
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(UNLIMITED));

        // Only the payer is a balance-sheet manager, and only of this vault's pool.
        vm.mockCall(spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.manager.selector), abi.encode(false));
        vm.mockCall(
            spokeRegistry, abi.encodeWithSelector(ISpokeRegistry.manager.selector, POOL, payer), abi.encode(true)
        );

        _enableBooking(POOL, address(asset));
        _setLimit(UNLIMITED);
        _setCredit(UNLIMITED);
    }

    /// @dev What a pool configures so a draw can be booked: the route as its spoke manager and as an
    ///      accounting token minter, and the liability token registered on the spoke.
    function _enableBooking(PoolId poolId, address asset_) internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.manager.selector, poolId, address(route)),
            abi.encode(true)
        );
        vm.prank(envoy);
        accountingToken.fromHub(poolId, abi.encode(address(route).toBytes32(), true));
        _registerLiability(poolId, asset_, newAssetId(0, 2));
    }

    function _registerLiability(PoolId poolId, address asset_, AssetId assetId) internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSignature(
                "assetToId(address,uint256)", address(accountingToken), accountingToken.toTokenId(poolId, asset_, true)
            ),
            abi.encode(assetId)
        );
    }

    function _setLimit(uint128 limit) internal {
        vm.prank(envoy);
        route.fromHub(POOL, abi.encode(vault, limit));
    }

    function _setCredit(uint128 credit) internal {
        vm.prank(provider);
        route.setCredit(vault, credit);
    }

    function _draw(uint128 assets) internal {
        vm.prank(vault);
        route.provide(vault, assets);
    }

    //----------------------------------------------------------------------------------------------
    // Enablement
    //----------------------------------------------------------------------------------------------

    function testSetLimitAndSetCreditEmitThePool() public {
        vm.expectEmit(true, true, false, true);
        emit IBasinLiquidityRoute.SetLimit(POOL, vault, 500e6);
        _setLimit(500e6);

        vm.expectEmit(true, true, false, true);
        emit IBasinLiquidityRoute.SetCredit(POOL, vault, 300e6);
        _setCredit(300e6);
    }

    function testOnlyEnvoySetsTheLimit() public {
        vm.expectRevert(IBasinLiquidityRoute.NotEnvoy.selector);
        route.fromHub(POOL, abi.encode(vault, UNLIMITED));
    }

    function testSetLimitRejectsValue() public {
        vm.deal(envoy, 1 ether);
        vm.prank(envoy);
        vm.expectRevert(IBasinLiquidityRoute.UnexpectedValue.selector);
        route.fromHub{value: 1}(POOL, abi.encode(vault, UNLIMITED));
    }

    /// @dev Without the pool binding, any pool reaching the Envoy could raise the limit of another
    ///      pool's vault.
    function testSetLimitBindsToThePoolOwningTheVault() public {
        vm.prank(envoy);
        vm.expectRevert(IBasinLiquidityRoute.WrongPool.selector);
        route.fromHub(OTHER_POOL, abi.encode(vault, UNLIMITED));
    }

    /// @dev The venue's side of the line. Any pool can set a limit for its own vault, so without this
    ///      a pool the liquidity provider never heard of could draw on its basin.
    function testOnlyTheLiquidityProviderExtendsCredit() public {
        vm.prank(outsider);
        vm.expectRevert(IBasinLiquidityRoute.NotLiquidityProvider.selector);
        route.setCredit(vault, UNLIMITED);

        vm.prank(envoy);
        vm.expectRevert(IBasinLiquidityRoute.NotLiquidityProvider.selector);
        route.setCredit(vault, UNLIMITED);
    }

    /// @dev Either side withdrawing its limit closes the line.
    function testAZeroLimitOnEitherSideDisablesTheVault() public {
        basin.setWithdrawable(1_000e6);
        assertEq(route.available(vault), 1_000e6, "enabled");

        _setLimit(0);
        assertEq(route.available(vault), 0, "the pool disabled it");
        vm.prank(vault);
        vm.expectRevert(IBasinLiquidityRoute.ExceedsLimit.selector);
        route.provide(vault, 1);

        _setLimit(UNLIMITED);
        _setCredit(0);
        assertEq(route.available(vault), 0, "the venue disabled it");
        vm.prank(vault);
        vm.expectRevert(IBasinLiquidityRoute.ExceedsLimit.selector);
        route.provide(vault, 1);
    }

    //----------------------------------------------------------------------------------------------
    // Credit line
    //----------------------------------------------------------------------------------------------

    /// @dev `available` is the venue's liquidity bounded by the lower of the two limits.
    function testAvailableIsTheLowerOfTheLimitsAndTheVenue() public {
        basin.setWithdrawable(1_000e6);

        _setLimit(500e6);
        _setCredit(800e6);
        assertEq(route.available(vault), 500e6, "the pool's limit binds");

        _setCredit(300e6);
        assertEq(route.available(vault), 300e6, "the venue's credit binds");

        _setLimit(UNLIMITED);
        _setCredit(UNLIMITED);
        basin.setWithdrawable(200e6);
        assertEq(route.available(vault), 200e6, "the venue's liquidity binds");
    }

    /// @dev What a vault has drawn and not repaid comes off its line.
    function testAvailableIsNettedAgainstTheReceivable(uint128 limit, uint128 drawn) public {
        limit = uint128(bound(limit, 1, 1e30));
        drawn = uint128(bound(drawn, 1, limit));
        basin.setWithdrawable(type(uint256).max);
        _setLimit(limit);

        _draw(drawn);

        assertEq(route.available(vault), limit - drawn, "the line less the receivable");
    }

    /// @dev Lowering a limit below what is owed leaves no headroom rather than underflowing, so the
    ///      capacity views keep answering.
    function testAvailableSaturatesAtZero() public {
        basin.setWithdrawable(1_000e6);
        _draw(600e6);

        _setLimit(400e6);
        assertEq(route.available(vault), 0, "owing more than the limit leaves nothing to draw");

        vm.prank(vault);
        vm.expectRevert(IBasinLiquidityRoute.ExceedsLimit.selector);
        route.provide(vault, 1);
    }

    function testProvideEnforcesTheLine() public {
        basin.setWithdrawable(1_000e6);
        _setLimit(500e6);
        _draw(300e6);

        vm.prank(vault);
        vm.expectRevert(IBasinLiquidityRoute.ExceedsLimit.selector);
        route.provide(vault, 200e6 + 1);

        _draw(200e6);
        assertEq(route.receivable(vault), 500e6, "drawn up to the line exactly");
    }

    /// @dev Repaying restores the line, which is what makes it revolving.
    function testRepayingRestoresTheLine() public {
        basin.setWithdrawable(1_000e6);
        _setLimit(500e6);
        _draw(500e6);
        assertEq(route.available(vault), 0, "the line is used up");

        asset.mint(payer, 200e6);
        vm.prank(payer);
        route.repay(vault, 200e6);

        assertEq(route.available(vault), 200e6, "what was repaid can be drawn again");
    }

    //----------------------------------------------------------------------------------------------
    // Providing
    //----------------------------------------------------------------------------------------------

    /// @dev Only the vault itself may pull: `provide` moves funds and records a debt against the
    ///      vault, so a third party calling it for someone else's vault would be funding an exit
    ///      nobody asked for.
    function testOnlyTheVaultMayDraw() public {
        vm.prank(outsider);
        vm.expectRevert(IBasinLiquidityRoute.NotVault.selector);
        route.provide(vault, 1e6);
    }

    /// @dev This route only sources liquidity out; the deposit-side `forward` leg is optional, so it
    ///      is a no-op that moves nothing. Callable by anyone (it does nothing), leaves the receivable
    ///      and the escrow untouched.
    function testForwardIsANoOp() public {
        basin.setWithdrawable(1_000e6);

        vm.prank(vault);
        route.forward(vault, 1_000e6);

        assertEq(route.receivable(vault), 0, "forward records no debt");
        assertEq(asset.balanceOf(escrow), 0, "forward moves nothing into the escrow");
        assertEq(route.available(vault), 1_000e6, "and does not disturb what can be sourced out");
    }

    function testProvideLandsInTheEscrowAndRecordsTheDebt(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e30));
        basin.setWithdrawable(amount);

        vm.expectEmit(true, true, false, true);
        emit IBasinLiquidityRoute.BasinProvided(POOL, vault, amount);
        _draw(amount);

        assertEq(asset.balanceOf(vault), amount, "drawn liquidity is paid to the vault, to forward into its escrow");
        assertEq(route.receivable(vault), amount, "and is recorded as owed");
    }

    /// @dev All-or-nothing: a basin that pays out less than asked must fail the draw rather than
    ///      leave the vault short mid-redemption.
    function testProvideIsAllOrNothing() public {
        basin.setWithdrawable(1_000e6);
        basin.setCap(999e6);

        vm.prank(vault);
        vm.expectRevert(IBasinLiquidityRoute.InsufficientLiquidity.selector);
        route.provide(vault, 1_000e6);
    }

    /// @dev The vault notes the drawn amount as deposited once `provide` returns, so what arrived is
    ///      measured at the vault rather than taken from the venue's return value.
    function testAVenueThatOverstatesItsPayoutIsRefused() public {
        basin.setWithdrawable(1_000e6);
        basin.setCap(999e6);
        basin.setOverstates(true);

        vm.prank(vault);
        vm.expectRevert(IBasinLiquidityRoute.InsufficientLiquidity.selector);
        route.provide(vault, 1_000e6);
    }

    /// @dev `available` must not revert, since it backs the vault's `max*` and its instant lane: a
    ///      venue that cannot quote reads as no liquidity.
    function testAVenueThatCannotQuoteReportsNothing() public {
        basin.setWithdrawable(1_000e6);
        basin.setBroken(true);

        assertEq(route.available(vault), 0);
    }

    /// @dev A short answer is not decoded into a revert either.
    function testAVenueThatAnswersShortReportsNothing() public {
        basin.setWithdrawable(1_000e6);
        basin.setShort(true);

        assertEq(route.available(vault), 0);
    }

    function testDrawsAccumulate() public {
        basin.setWithdrawable(1_000e6);

        _draw(400e6);
        _draw(600e6);

        assertEq(route.receivable(vault), 1_000e6);
        assertEq(asset.balanceOf(vault), 1_000e6);
    }

    /// @dev `n`, and deployment constraint 4: one route serves every vault enabled on it, and those
    ///      vaults need not belong to the same pool. Each vault's draw is bounded by its own line, but
    ///      the venue's liquidity is not reserved per line: two pools whose lines together exceed the
    ///      basin each see it, and whichever draws first takes it. Nothing here is stolen — the draw
    ///      is paid to the drawing vault, within the line the venue extended to it.
    function testTwoPoolsShareOneVenueAndTheFirstToDrawTakesIt() public {
        address otherVault = address(new IsContract());
        PoolId otherPool = PoolId.wrap(7);
        address otherEscrow = makeAddr("otherEscrow");

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector, otherVault),
            abi.encode(
                VaultDetails(
                    otherPool, ShareClassId.wrap(bytes16("sc7")), newAssetId(0, 1), address(asset), uint256(0), true
                )
            )
        );
        vm.mockCall(otherVault, abi.encodeWithSelector(IVault.poolId.selector), abi.encode(otherPool));
        vm.mockCall(
            otherVault, abi.encodeWithSelector(IVault.scId.selector), abi.encode(ShareClassId.wrap(bytes16("sc7")))
        );
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.escrow.selector, otherPool), abi.encode(otherEscrow));
        _enableBooking(otherPool, address(asset));
        vm.prank(envoy);
        route.fromHub(otherPool, abi.encode(otherVault, UNLIMITED));
        vm.prank(provider);
        route.setCredit(otherVault, 800e6);
        _setCredit(800e6);

        basin.setWithdrawable(1_000e6);

        // Each pool is told what its own line allows of the venue.
        assertEq(route.available(vault), 800e6, "the first pool sees its line");
        assertEq(route.available(otherVault), 800e6, "and so does the second");

        // The first to draw takes it.
        _draw(800e6);
        assertEq(asset.balanceOf(vault), 800e6, "paid to the drawing vault");

        // The other pool's quote was never a reservation.
        basin.setWithdrawable(200e6);
        assertEq(route.available(otherVault), 200e6, "and the second pool's capacity shrank");
    }

    /// @dev `available` is advisory — the vault reads it to size a draw, and overstating it makes the
    ///      draw revert rather than losing anything.
    function testAvailableReportsTheBasinBalance(uint256 withdrawable) public {
        basin.setWithdrawable(withdrawable);
        assertEq(route.available(vault), withdrawable > type(uint128).max ? type(uint128).max : uint128(withdrawable));
    }

    //----------------------------------------------------------------------------------------------
    // Liability
    //----------------------------------------------------------------------------------------------

    /// @dev The draw lands as cash the pool owes, so its debt is deposited into the vault's share
    ///      class beside it, as the pool's liability token for the asset drawn.
    function testADrawBooksItsDebtAsALiability(uint128 amount) public {
        amount = uint128(bound(amount, 1, 1e30));
        basin.setWithdrawable(amount);

        vm.expectCall(spoke, abi.encodeCall(ISpoke.deposit, (POOL, SC, address(accountingToken), liabilityId, amount)));
        _draw(amount);

        assertTrue(accountingToken.isLiability(liabilityId), "booked as a liability");
        assertEq(
            accountingToken.allowance(address(route), spoke, liabilityId), amount, "the spoke may take the debt in"
        );
        // The spoke is mocked, so the minted debt stays with the route rather than reaching the escrow.
        assertEq(accountingToken.balanceOf(address(route), liabilityId), amount, "minted for exactly the draw");
    }

    /// @dev Repaying takes the same amount of debt back out of the escrow and burns it.
    function testRepayingWithdrawsAndBurnsTheLiability(uint128 drawn, uint128 repaid) public {
        drawn = uint128(bound(drawn, 1, 1e30));
        repaid = uint128(bound(repaid, 1, drawn));
        basin.setWithdrawable(drawn);
        _draw(drawn);

        asset.mint(payer, repaid);
        vm.expectCall(
            spoke,
            abi.encodeCall(ISpoke.withdraw, (POOL, SC, address(accountingToken), liabilityId, address(route), repaid))
        );
        vm.prank(payer);
        route.repay(vault, repaid);

        assertEq(accountingToken.balanceOf(address(route), liabilityId), drawn - repaid, "burnt what was repaid");
    }

    /// @dev Fail closed: a draw whose debt cannot be booked does not happen. Each missing piece of the
    ///      pool's setup takes the capacity to zero, so the vault never advertises an exit that reverts.
    function testAPoolThatCannotBookTheDebtOffersNoCapacity() public {
        basin.setWithdrawable(1_000e6);
        assertEq(route.available(vault), 1_000e6, "configured");

        vm.prank(envoy);
        accountingToken.fromHub(POOL, abi.encode(address(route).toBytes32(), false));
        assertEq(route.available(vault), 0, "not a minter");
        vm.prank(vault);
        vm.expectRevert(IAccountingToken.NotMinter.selector);
        route.provide(vault, 1e6);
        vm.prank(envoy);
        accountingToken.fromHub(POOL, abi.encode(address(route).toBytes32(), true));

        _registerLiability(POOL, address(asset), AssetId.wrap(0));
        assertEq(route.available(vault), 0, "the liability token is not a spoke asset");
        _registerLiability(POOL, address(asset), newAssetId(0, 2));

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.manager.selector, POOL, address(route)),
            abi.encode(false)
        );
        assertEq(route.available(vault), 0, "not a manager of the pool");

        assertEq(route.receivable(vault), 0, "nothing was drawn");
    }

    /// @dev The minter right is per pool, so a pool that enabled the route cannot have another pool's
    ///      debt minted through it.
    function testBookingIsPerPool() public view {
        assertTrue(accountingToken.minters(POOL, address(route)), "the route mints for its pool");
        assertFalse(accountingToken.minters(OTHER_POOL, address(route)), "and for no other");
    }

    //----------------------------------------------------------------------------------------------
    // Repaying
    //----------------------------------------------------------------------------------------------

    function testRepayReturnsLiquidityToTheProvider(uint128 drawn, uint128 repaid) public {
        drawn = uint128(bound(drawn, 1, 1e30));
        repaid = uint128(bound(repaid, 1, drawn));
        basin.setWithdrawable(drawn);

        _draw(drawn);

        asset.mint(payer, repaid);
        vm.expectEmit(true, true, true, true);
        emit IBasinLiquidityRoute.BasinRepaid(POOL, vault, payer, repaid);
        vm.prank(payer);
        route.repay(vault, repaid);

        assertEq(asset.balanceOf(provider), repaid, "repayment goes to the basin's liquidity provider");
        assertEq(route.receivable(vault), drawn - repaid, "and clears that much of the debt");
    }

    /// @dev Repaying restores the vault's line, so it is the pool's decision: only a balance-sheet
    ///      manager of the vault's own pool may settle, whoever else holds the asset.
    function testOnlyAManagerOfTheVaultsPoolMayRepay() public {
        basin.setWithdrawable(100e6);
        _draw(100e6);

        asset.mint(outsider, 100e6);
        vm.prank(outsider);
        vm.expectRevert(IBasinLiquidityRoute.NotManager.selector);
        route.repay(vault, 100e6);

        // A manager of another pool is an outsider here.
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.manager.selector, OTHER_POOL, outsider),
            abi.encode(true)
        );
        vm.prank(outsider);
        vm.expectRevert(IBasinLiquidityRoute.NotManager.selector);
        route.repay(vault, 100e6);

        assertEq(route.receivable(vault), 100e6, "the debt is untouched");
    }

    /// @dev A route that lost its minter role cannot unbook, but the provider is still paid and the
    ///      line reopened: the liability stays for the pool to clear and is reported.
    function testRepayWithoutTheRolesLeavesTheLiabilityBooked() public {
        basin.setWithdrawable(100e6);
        _draw(100e6);
        vm.prank(envoy);
        accountingToken.fromHub(POOL, abi.encode(address(route).toBytes32(), false));

        asset.mint(payer, 100e6);
        vm.expectEmit();
        emit IBasinLiquidityRoute.BasinLiabilityLeftBooked(POOL, vault, 100e6);
        vm.prank(payer);
        route.repay(vault, 100e6);

        assertEq(route.receivable(vault), 0, "the debt is repaid");
        assertEq(asset.balanceOf(provider), 100e6, "the provider is paid");
        assertEq(accountingToken.balanceOf(address(route), liabilityId), 100e6, "nothing was burnt");
    }

    /// @dev Another manager moved part of the liability out of the escrow: the route unbooks what is
    ///      left and reports the rest.
    function testRepayUnbooksOnlyWhatTheEscrowHolds() public {
        basin.setWithdrawable(100e6);
        _draw(100e6);
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(30e6)));

        asset.mint(payer, 100e6);
        vm.expectCall(
            spoke,
            abi.encodeCall(ISpoke.withdraw, (POOL, SC, address(accountingToken), liabilityId, address(route), 30e6))
        );
        vm.expectEmit();
        emit IBasinLiquidityRoute.BasinLiabilityLeftBooked(POOL, vault, 70e6);
        vm.prank(payer);
        route.repay(vault, 100e6);

        assertEq(route.receivable(vault), 0, "the debt is repaid");
        assertEq(accountingToken.balanceOf(address(route), liabilityId), 70e6, "burnt what was withdrawn");
    }

    /// @dev The bound is the receivable itself, so nobody can repay more than was drawn.
    function testRepayCannotExceedTheReceivable() public {
        basin.setWithdrawable(100e6);
        _draw(100e6);

        asset.mint(payer, 200e6);
        vm.prank(payer);
        vm.expectRevert();
        route.repay(vault, 101e6);
    }

    /// @dev Tokens sent to the route by mistake are not any pool's, so Root can return them.
    function testRootRecoversTokensSentToTheRoute() public {
        asset.mint(address(route), 5e6);

        vm.prank(makeAddr("root"));
        route.recoverTokens(address(asset), outsider, 5e6);

        assertEq(asset.balanceOf(outsider), 5e6);
        assertEq(asset.balanceOf(address(route)), 0);
    }

    function testOnlyRootRecoversTokens() public {
        asset.mint(address(route), 5e6);

        vm.prank(outsider);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        route.recoverTokens(address(asset), outsider, 5e6);
    }
}
