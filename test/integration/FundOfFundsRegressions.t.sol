// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FundOfFundsBasinTest} from "./FundOfFundsBasin.t.sol";

import {ERC20} from "../../src/misc/ERC20.sol";
import {d18} from "../../src/misc/types/D18.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {RequestId} from "../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {VaultUpdateKind} from "../../src/core/messaging/libraries/MessageLib.sol";

import {IVaultErrors} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {IVaultLiquidityRoute} from "../../src/vaults/liquidity/interfaces/IVaultLiquidityRoute.sol";

import {ITransferHook} from "../../src/token/interfaces/ITransferHook.sol";

/// @dev Looks like a 1:1 vault on its pool's share token to every view the route reads, but `share()`
///      names whatever token it is told to, and it pays out only `deliverBps` of what it is asked for.
contract FakeUnderlying {
    ERC20 public immutable asset;
    ERC20 public immutable registryShare;
    PoolId public immutable poolId;
    ShareClassId public immutable scId;
    address public share;
    uint256 public deliverBps = 10_000;

    /// @dev Answers for the pool and share class its pool links it under, as a vault its factory built does
    constructor(ERC20 asset_, ERC20 registryShare_, PoolId poolId_, ShareClassId scId_) {
        asset = asset_;
        registryShare = registryShare_;
        poolId = poolId_;
        scId = scId_;
        share = address(registryShare_);
    }

    function setShare(address share_) external {
        share = share_;
    }

    function setDeliverBps(uint256 bps) external {
        deliverBps = bps;
    }

    function maxWithdraw(address) external pure returns (uint256) {
        return type(uint128).max;
    }

    function withdrawCapacity(address) external pure returns (uint256) {
        return type(uint128).max;
    }

    function previewRedeem(uint256 shares) external pure returns (uint256) {
        return shares / 1e12;
    }

    function previewWithdraw(uint256 assets) external pure returns (uint256) {
        return assets * 1e12;
    }

    function withdraw(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = assets * 1e12;
        registryShare.transferFrom(msg.sender, address(this), shares);
        asset.transfer(receiver, assets * deliverBps / 10_000);
    }
}

/// @dev A vault factory that "deploys" a contract chosen in advance. Linking through it is permitted
///      to any pool for its own share classes, behind that pool's own policy.
contract FakeVaultFactory {
    address public immutable vault;

    constructor(address vault_) {
        vault = vault_;
    }

    function newVault(PoolId, ShareClassId, address, uint256, address, bytes calldata) external view returns (address) {
        return vault;
    }
}

/// @dev The security review's fund-of-funds findings, replayed as their PoCs on the real two-pool chain
///      and asserting the fixed behaviour: C-4 (custody), M-1 (pool isolation) and M-2 (boundary).
/// forge-config: default.isolate = true
contract FundOfFundsRegressionTest is FundOfFundsBasinTest {
    using CastLib for *;

    address immutable CLEAN = makeAddr("CLEAN");

    function _memberOfJtrsy(address who) internal {
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(who), EXTRA_GAS, REFUND
        );
    }

    /// @dev The route, not the top pool's escrow, takes the underlying position and is paid by the underlying vault,
    ///      so the escrow's exemption does not cover it. Under every preset that asks membership the underlying pool
    ///      has to make the route a member: until it does, the route reads no capacity and the top vault quietly
    ///      falls back to its own cash. Under `FreezeOnly`, which the rest of this chain runs on, no step is needed.
    function testTheUnderlyingPoolMustMakeTheRouteAMemberUnderARestrictivePreset() public {
        _setUpChain();
        assertEq(vaultRoute.available(address(topVault)), LINE, "FreezeOnly needs no membership");

        vm.startPrank(FM);
        _setHook(s, address(deployA.fullRestrictionsHook()));
        vm.stopPrank();
        assertEq(vaultRoute.available(address(topVault)), 0, "a route that is no member reads no capacity");
        assertEq(topVault.maxWithdraw(INVESTOR_A), 0, "so the top vault offers none of the underlying's liquidity");

        _memberOfJtrsy(address(vaultRoute));
        assertEq(vaultRoute.available(address(topVault)), LINE, "a member route reads the line again");
        assertEq(topVault.maxWithdraw(INVESTOR_A), LINE);
    }

    //----------------------------------------------------------------------------------------------
    // C-4: an escrow counts as a member on a vault action
    //----------------------------------------------------------------------------------------------

    /// @dev sec-custody `ShareCustodyFoFPoC`: a redemption of jTRSY paid into the top pool's escrow
    ///      failed the vault-action membership check, so a fund of funds had to be whitelisted on every
    ///      underlying it held. Under FreelyTransferable, which holds the claim's receiver to
    ///      membership, the top escrow now receives the claim while a non-member still cannot.
    function testAnUnderlyingRedemptionCanBeClaimedIntoAnEscrow() public {
        _setUpChain();
        vm.startPrank(FM);
        _setHook(s, address(deployA.freelyTransferableHook()));
        vm.stopPrank();
        _memberOfJtrsy(INVESTOR_A);
        address topEscrow = topVault.escrow();

        uint128 amount = 100e6;
        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(jtrsyVault), amount);
        uint256 shares = jtrsyVault.deposit(amount, INVESTOR_A);
        RequestId requestId = RequestId.wrap(jtrsyVault.requestRedeem(shares, INVESTOR_A, INVESTOR_A));
        vm.stopPrank();

        // jTRSY's escrow is fully deployed; its manager brings back the cash the fill pays out.
        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, amount);
        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), amount);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, amount);
        vm.stopPrank();
        _fulfill(false, requestId, uint128(shares));
        uint256 claimable = jtrsyVault.maxWithdraw(INVESTOR_A);
        assertEq(claimable, amount, "the redemption settled");

        vm.prank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        jtrsyVault.withdraw(claimable, CLEAN, INVESTOR_A);

        uint256 before = s.usdc.balanceOf(topEscrow);
        vm.prank(INVESTOR_A);
        jtrsyVault.withdraw(claimable, topEscrow, INVESTOR_A);
        assertEq(s.usdc.balanceOf(topEscrow) - before, claimable, "paid into the top pool's escrow");
    }

    //----------------------------------------------------------------------------------------------
    // M-1: the route releases the registry's token, and refuses an underlying that underpays
    //----------------------------------------------------------------------------------------------

    /// @dev Links a contract of jTRSY's pool's choosing as a jTRSY vault, through its own factory, and
    ///      routes the top vault through it: every step the top pool reviews checks out.
    function _routeThroughAFake() internal returns (FakeUnderlying fake, ERC20 other) {
        fake = new FakeUnderlying(s.usdc, ERC20(address(jtrsy)), POOL_A, SC_1);
        s.usdc.mint(address(fake), VENUE);
        FakeVaultFactory factory = new FakeVaultFactory(address(fake));

        vm.startPrank(FM);
        h.hub.updateVault{value: GAS}(
            POOL_A,
            SC_1,
            s.usdcId,
            address(factory).toBytes32(),
            VaultUpdateKind.DeployAndLink,
            bytes(""),
            EXTRA_GAS,
            REFUND
        );
        vm.stopPrank();
        assertTrue(s.spokeRegistry.isLinked(address(fake)), "the fake is a linked vault of jTRSY's pool");

        address[] memory routes = new address[](1);
        routes[0] = address(fake);
        _managerCall(
            POOL_A,
            address(vaultRoute),
            abi.encode(IVaultLiquidityRoute.ConfigKind.Consent, address(fake), abi.encode(address(topVault), true))
        );
        _managerCall(
            topPool,
            address(vaultRoute),
            abi.encode(IVaultLiquidityRoute.ConfigKind.Routes, address(topVault), abi.encode(routes))
        );

        // A second asset the top pool holds under the same share class.
        other = new ERC20(18);
        other.mint(BSM, 1_000e18);
        vm.startPrank(ANY);
        s.spoke.registerAsset{value: GAS}(h.centrifugeId, address(other), 0, ANY);
        vm.stopPrank();
        vm.startPrank(BSM);
        other.approve(address(s.spoke), 1_000e18);
        s.spoke.deposit(topPool, topSc, address(other), 0, 1_000e18);
        vm.stopPrank();
    }

    /// @dev sec-pool-isolation M-1: the route asked the underlying which token to release, so an
    ///      underlying naming another of the top pool's assets drew that asset out of its escrow. The
    ///      token now comes from the registry: only the top pool's jTRSY position moves.
    function testTheRouteReleasesTheRegistrysTokenNotTheUnderlyings() public {
        _setUpChain();
        (FakeUnderlying fake, ERC20 other) = _routeThroughAFake();
        fake.setShare(address(other));
        address topEscrow = topVault.escrow();
        uint256 jtrsyBefore = jtrsy.balanceOf(topEscrow);

        vm.prank(INVESTOR_A);
        topVault.withdraw(250e6, INVESTOR_A);

        assertEq(other.balanceOf(topEscrow), 1_000e18, "the asset the underlying named never left");
        assertEq(other.balanceOf(address(fake)), 0);
        assertEq(jtrsy.balanceOf(topEscrow), jtrsyBefore - 250e18, "the jTRSY position paid for the draw");
        assertEq(jtrsy.balanceOf(address(fake)), 250e18);
        assertEq(s.usdc.balanceOf(INVESTOR_A), USDC_AMOUNT_1 - DEPOSIT + 250e6, "and the investor was paid");
    }

    /// @dev M-1's second half: nothing checked the underlying delivered, so the shortfall was noted as
    ///      deposited and paid out of whatever else the escrow held. A short delivery now reverts the
    ///      exit, and the position stays where it was.
    function testAnUnderlyingThatUnderdeliversIsRefused() public {
        _setUpChain();
        (FakeUnderlying fake,) = _routeThroughAFake();
        fake.setDeliverBps(5_000);
        uint256 jtrsyBefore = jtrsy.balanceOf(topVault.escrow());

        vm.prank(INVESTOR_A);
        vm.expectRevert(IVaultLiquidityRoute.InsufficientLiquidity.selector);
        topVault.withdraw(250e6, INVESTOR_A);

        assertEq(jtrsy.balanceOf(topVault.escrow()), jtrsyBefore, "the position stayed");
        assertEq(fof.balanceOf(INVESTOR_A), DEPOSIT * 1e12, "and so did the investor's shares");
    }

    //----------------------------------------------------------------------------------------------
    // M-2: an underlying pool's invalid prices do not take down the top vault's own lane
    //----------------------------------------------------------------------------------------------

    uint128 constant OWN_LIQUIDITY = 500e6;

    function _fundTopEscrow() internal {
        vm.prank(ERC20_DEPLOYER);
        s.usdc.mint(BSM, OWN_LIQUIDITY);
        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), OWN_LIQUIDITY);
        s.spoke.deposit(topPool, topSc, address(s.usdc), 0, OWN_LIQUIDITY);
        vm.stopPrank();
    }

    /// @dev Exits the top escrow can pay alone go through, on both entrypoints, and both views report
    ///      that escrow rather than reverting.
    function _assertOwnLiquidityStillExits() internal {
        assertEq(vaultRoute.available(address(topVault)), 0, "the route quotes nothing");
        assertEq(topVault.maxWithdraw(INVESTOR_A), OWN_LIQUIDITY, "maxWithdraw is the top escrow's");
        assertEq(topVault.maxRedeem(INVESTOR_A), uint256(OWN_LIQUIDITY) * 1e12, "and so is maxRedeem");

        uint256 before = s.usdc.balanceOf(INVESTOR_A);
        vm.startPrank(INVESTOR_A);
        topVault.withdraw(100e6, INVESTOR_A);
        topVault.redeem(100e18, INVESTOR_A);
        vm.stopPrank();
        assertEq(s.usdc.balanceOf(INVESTOR_A) - before, 200e6, "paid from the top escrow");
        assertEq(s.usdc.balanceOf(address(basin)), VENUE, "without touching the venue");
    }

    /// @dev sec-boundary `SecBoundaryRoutePoC`, pause: jTRSY's pool pausing its own oracle reverted
    ///      every jTRSY quote, which took down the top vault's views and every instant exit.
    function testAnUnderlyingPoolPausingItsOracleLeavesTheTopVaultsLane() public {
        _setUpChain();
        _fundTopEscrow();

        _managerCall(POOL_A, address(s.spokeOracle), abi.encode(true));
        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        jtrsyVault.previewRedeem(1e18);

        _assertOwnLiquidityStillExits();
    }

    /// @dev Same, with no deliberate action: jTRSY's prices simply go stale while the top pool keeps
    ///      its own fresh.
    function testAnUnderlyingPoolsStalePricesLeaveTheTopVaultsLane() public {
        _setUpChain();
        _fundTopEscrow();

        vm.warp(block.timestamp + 2 days);
        vm.startPrank(FM);
        h.hub.updateSharePrice(topPool, topSc, d18(1, 1), uint64(block.timestamp));
        h.hub.notifySharePrice{value: GAS}(topPool, topSc, s.centrifugeId, REFUND);
        h.hub.notifyAssetPrice{value: GAS}(topPool, topSc, s.usdcId, REFUND);
        vm.stopPrank();

        (,, bool topValid) = s.spokeOracle.prices(topPool, topSc, s.usdcId);
        (,, bool jtrsyValid) = s.spokeOracle.prices(POOL_A, SC_1, s.usdcId);
        assertTrue(topValid, "the top pool's prices are fresh");
        assertFalse(jtrsyValid, "jTRSY's are stale");

        _assertOwnLiquidityStillExits();
    }
}
