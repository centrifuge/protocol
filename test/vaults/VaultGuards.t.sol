// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AmpleEscrow, IsContract, MockERC20, MockShareToken} from "./Vault.t.sol";

import {D18} from "../../src/misc/types/D18.sol";
import {IAuth} from "../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../src/misc/libraries/CastLib.sol";
import {IERC7575} from "../../src/misc/interfaces/IERC7575.sol";
import {IERC7540Deposit, IERC7540Operator} from "../../src/misc/interfaces/IERC7540.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {ISpoke} from "../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {AssetId, newAssetId} from "../../src/core/types/AssetId.sol";
import {ISpokeRegistry, VaultDetails} from "../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {
    IVaultRequestManager,
    IVaultDepositCallbacks,
    IVaultRedeemCallbacks
} from "../../src/vaults/messaging/interfaces/IVaultRequestManager.sol";

import {Vault} from "../../src/vaults/Vault.sol";
import {IVaultOracle} from "../../src/vaults/oracles/interfaces/IVaultOracle.sol";
import {VaultRequestIdLib} from "../../src/vaults/libraries/VaultRequestIdLib.sol";
import {VaultAction, VaultActionKind, VaultActionLib} from "../../src/vaults/libraries/VaultActionLib.sol";
import {PerInvestorPolicy, PerPeriodPolicy, PerRequestPolicy} from "../../src/vaults/policies/RequestPolicies.sol";
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

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";
import {IRoleHook, Role, RoleCheck, Effect} from "../../src/token/interfaces/IRoleHook.sol";

/// @dev The vault's refusals. `Vault.t.sol` covers what the flows do when they are allowed to run;
///      this covers what stops them — the caller checks, the zero and limit guards, the fee-recipient
///      rules, and the fail-closed behaviour of the capacity views when a policy or hook misbehaves.
contract VaultGuardsTest is Test {
    PoolId constant POOL = PoolId.wrap(1);
    ShareClassId constant SC = ShareClassId.wrap(bytes16("sc1"));
    AssetId immutable ASSET_ID = newAssetId(0, 1);

    D18 constant ONE = D18.wrap(1e18);
    D18 constant ZERO = D18.wrap(0);

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

    Vault vault;
    IAsyncVault v;

    address controller = makeAddr("controller");
    address receiver = makeAddr("receiver");
    address outsider = makeAddr("outsider");
    address feeRecipient = makeAddr("feeRecipient");

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
                    liquidityRoute: ILiquidityRoute(address(0)),
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
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(true));
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
        vm.mockCall(spoke, abi.encodeWithSelector(ISpoke.availableBalanceOf.selector), abi.encode(uint128(1_000_000e6)));

        _instantCaps(1_000_000e6, 1_000_000e6);
        _instantFees(0, 0);
    }

    function _instantCaps(uint128 depositCap, uint128 redeemCap) internal {
        vm.mockCall(
            instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector), abi.encode(depositCap)
        );
        vm.mockCall(
            instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector), abi.encode(redeemCap)
        );
    }

    function _instantFees(int128 depositFee, int128 redeemFee) internal {
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(depositFee, depositFee == 0 ? address(0) : feeRecipient)
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(redeemFee, redeemFee == 0 ? address(0) : feeRecipient)
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
    }

    /// @dev A retained fee, which the pool keeps rather than paying out: it reaches the escrow (or
    ///      stays in it) but backs no shares, so it accrues to the holders who were already there.
    function _instantRetained(uint128 retained) internal {
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(retained), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(retained), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
    }

    function _prices(D18 ppa, D18 pps) internal {
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ppa, pps, true));
    }

    function _requestId(uint96 localId) internal view returns (uint256) {
        return VaultRequestIdLib.from(address(vault), localId).raw();
    }

    function _requestDeposit(uint128 amount) internal returns (uint96 localId) {
        vm.prank(controller);
        uint256 requestId = v.requestDeposit(amount, controller, controller);
        return uint96(requestId);
    }

    function _requestRedeem(uint128 shares) internal returns (uint96 localId) {
        vm.prank(controller);
        uint256 requestId = v.requestRedeem(shares, controller, controller);
        return uint96(requestId);
    }

    //----------------------------------------------------------------------------------------------
    // Caller checks
    //----------------------------------------------------------------------------------------------

    /// @dev A position credited to another controller holds that controller's instant lane closed until it settles, so
    ///      the vault asks its instant policy who may fund one. A request a controller funds for itself is never asked.
    function testCreditingAnotherControllerAsksTheInstantPolicy() public {
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(false));
        _requestDeposit(1_000e6);
        _requestRedeem(1_000e18);

        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.requestDeposit(1_000e6, outsider, controller);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.requestRedeem(1_000e18, outsider, controller);
        vm.stopPrank();

        vm.mockCall(
            instantPolicy,
            abi.encodeCall(IInstantPolicy.canCredit, (address(vault), controller, outsider)),
            abi.encode(true)
        );
        vm.prank(controller);
        v.requestDeposit(1_000e6, outsider, controller);
    }

    /// @dev The sponsor's consent holds for the sponsor's own calls and its operators', not for a spender of its share
    ///      allowance: such a spender could otherwise credit any controller with the sponsor's standing, or close the
    ///      owner's instant lane by requesting a redemption for the owner as its own controller.
    function testASpenderOfTheOwnersAllowanceCannotUseItsConsent() public {
        address spender = makeAddr("spender");
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(true));
        _requestRedeem(1_000e18);

        vm.startPrank(spender);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.requestRedeem(1e18, controller, controller);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.requestRedeem(1e18, outsider, controller);
        vm.stopPrank();

        vm.prank(controller);
        v.setOperator(spender, true);
        vm.prank(spender);
        v.requestRedeem(1e18, outsider, controller);
    }

    /// @dev Every hub callback is manager-gated; the router is the only caller that may settle.
    function testAllCallbacksRejectAnyoneButTheRequestManager() public {
        vm.startPrank(outsider);

        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultDepositCallbacks(address(vault)).approveDeposits(1, 1);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultDepositCallbacks(address(vault)).issueShares(1, 1);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(1, 1, 1);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(1, 1, 1);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultRedeemCallbacks(address(vault)).revokeShares(1, 1, 1);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(1, 1, 1);
        vm.expectRevert(IAuth.NotAuthorized.selector);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(1, 1, 1);

        vm.stopPrank();
    }

    /// @dev ERC-7540 sets the status it is given, so an account may name itself: it is already its own controller,
    ///      so the entry changes nothing a call can see.
    function testAnAccountCanSetItselfAsOperator() public {
        vm.prank(controller);
        vm.expectEmit();
        emit IERC7540Operator.OperatorSet(controller, controller, true);
        assertTrue(v.setOperator(controller, true));
        assertTrue(v.isOperator(controller, controller));

        vm.prank(controller);
        assertTrue(v.setOperator(controller, false));
        assertFalse(v.isOperator(controller, controller));
    }

    /// @dev The registry takes any contract from a pool's factory, so a vault another pool registered under itself reads
    ///      as linked to the registry but not to this vault's own position, and refuses what an unlinked vault refuses.
    function testAVaultRegisteredUnderAnotherPoolIsNotLinked() public {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(PoolId.wrap(99), SC, ASSET_ID, address(asset), uint256(0), true))
        );

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestDeposit(1e6, controller, controller);
    }

    /// @dev An unlinked vault takes no requests, transfers or instant trades: it is the kill switch a pool
    ///      manager reaches for. Claims stay open, so a vault being wound down still pays out what it owes;
    ///      with nothing claimable they revert on the limit, not on the link.
    function testUnlinkedVaultRefusesEverythingButClaims() public {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), false))
        );

        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestDeposit(1e6, controller, controller);

        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestRedeem(1e18, controller, controller);

        // Nothing claimable, so the 2-arg forms route to the instant lane, which needs the link.
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.deposit(1e6, receiver);

        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.mint(1e18, receiver);

        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.withdraw(1e6, receiver);

        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.redeem(1e18, receiver);

        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.transferDepositRequest(1, controller, receiver);

        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.transferRedeemRequest(1, controller, receiver);

        // The 3-argument deposit is a claim, which an unlinked vault still pays, so with nothing claimable it
        // refuses for that reason and not for the link
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1e6, receiver, controller);
        vm.stopPrank();
    }

    /// @dev ERC-4626: the 3-arg `withdraw`/`redeem` by the owner reach the instant lane like the 2-arg forms.
    ///      An operator's call is a claim only, since the instant path burns the caller's shares.
    function testThreeArgExitsByTheOwnerTradeInstantly() public {
        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.revoke.selector, POOL, SC, uint128(1_000e18)));
        vm.prank(controller);
        v.redeem(1_000e18, receiver, controller);

        vm.prank(controller);
        v.withdraw(1_000e6, receiver, controller);

        address operator = makeAddr("operator");
        vm.prank(controller);
        v.setOperator(operator, true);
        vm.prank(operator);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.redeem(1_000e18, receiver, controller);
    }

    /// @dev The 3-arg `deposit`/`mint` are ERC-7540 claims and never trade: with nothing claimable they revert for
    ///      the controller as for an operator, so a claim that is retried after it landed cannot become a purchase
    ///      out of the caller's wallet. The 2-arg forms are the instant lane.
    function testThreeArgEntriesOnlyClaim() public {
        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver, controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.mint(1_000e18, receiver, controller);

        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.issue.selector));
        v.deposit(1_000e6, receiver);
        v.mint(1_000e18, receiver);
        vm.stopPrank();

        address operator = makeAddr("operator");
        vm.prank(controller);
        v.setOperator(operator, true);
        vm.startPrank(operator);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver, controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.mint(1_000e18, receiver, controller);
        vm.stopPrank();
    }

    /// @dev ERC-4626: the instant `maxWithdraw`/`maxRedeem` are bounded by the owner's shares, while
    ///      `withdrawCapacity` reports the lane alone for a caller that does not hold them yet.
    function testInstantMaxViewsAreBoundByTheOwnersShares() public {
        address holder = makeAddr("holder");
        share.setBalance(holder, 5e18);
        assertEq(v.maxRedeem(holder), 5e18, "redeem is bounded by the balance");
        assertEq(v.maxWithdraw(holder), 5e6, "and so is withdraw, at the oracle's prices");
        assertGt(v.withdrawCapacity(holder), 5e6, "the lane itself reaches further");

        share.setBalance(holder, 0);
        assertEq(v.maxRedeem(holder), 0);
        assertEq(v.maxWithdraw(holder), 0);
    }

    /// @dev A rebate adds to what a trade issues or pays, so the instant `max*` size the hook's room with it: a deposit
    ///      of `maxDeposit` issues no more shares than the hook allows, and a redemption of `maxRedeem` pays no more.
    function testTheInstantMaxViewsCountARebateAgainstTheHook() public {
        _instantFees(-10e6, -10e6);
        vm.mockCall(
            actionHook,
            abi.encodeWithSelector(IRoleHook.maxAllowed.selector),
            abi.encode(uint256(100e6), uint256(100e18))
        );

        uint256 assets = v.maxDeposit(controller);
        assertEq(assets, 90e6, "the deposit whose shares, rebate included, fill the room");
        assertLe((assets + 10e6) * 1e12, 100e18, "so the deposit issues within the hook's share limit");

        address holder = makeAddr("holder");
        share.setBalance(holder, 1_000e18);
        uint256 shares = v.maxRedeem(holder);
        assertEq(shares, 90e18, "the redemption whose payout, rebate included, fills the room");
        assertLe(shares / 1e12 + 10e6, 100e6, "so the redemption pays within the hook's payout limit");
    }

    /// @dev Indexers see a bucket leave for the hub.
    function testAFlushEmitsFlushRequest() public {
        vm.expectEmit(address(vault));
        emit IVaultEvents.RequestFlushed(_requestId(1), true, 1_000e6);
        _requestDeposit(1_000e6);
    }

    /// @dev An indexer replaying the log must see the request before the flush it causes, which a same-chain
    ///      manager can settle in the same call.
    function testTheRequestIsLoggedBeforeItsFlush() public {
        vm.recordLogs();
        _requestDeposit(1_000e6);

        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 requested = type(uint256).max;
        uint256 flushed = type(uint256).max;
        for (uint256 i; i < logs.length; i++) {
            if (logs[i].emitter != address(vault)) continue;
            if (logs[i].topics[0] == IERC7540Deposit.DepositRequest.selector) requested = i;
            if (logs[i].topics[0] == IVaultEvents.RequestFlushed.selector) flushed = i;
        }
        assertLt(requested, type(uint256).max, "requested");
        assertLt(requested, flushed, "the request is logged first");
    }

    /// @dev Winding down: once unlinked, a settled position is still claimed in full.
    function testAnUnlinkedVaultStillPaysOutClaims() public {
        _settleDeposit(1_000e6, 1_000e18);
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), false))
        );

        vm.prank(controller);
        assertEq(v.mint(1_000e18, receiver, controller), 1_000e6, "the claim pays out unlinked");
        assertEq(v.maxMint(controller), 0);
    }

    function testThreeArgClaimsRequireTheControllerOrItsOperator() public {
        vm.startPrank(outsider);

        vm.expectRevert(IVaultErrors.InvalidController.selector);
        v.deposit(1e6, receiver, controller);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        v.mint(1e18, receiver, controller);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        v.withdraw(1e6, receiver, controller);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        v.redeem(1e18, receiver, controller);

        vm.stopPrank();
    }

    function testDepositRequestRequiresTheOwnerOrItsOperator() public {
        vm.prank(outsider);
        vm.expectRevert(IVaultErrors.InvalidOwner.selector);
        v.requestDeposit(1e6, controller, controller);
    }

    /// @dev The vault fails closed: it declares no fallback, so a selector it does not serve reverts
    ///      rather than being silently swallowed.
    function testUnknownSelectorReverts() public {
        (bool ok, bytes memory ret) = address(vault).call(abi.encodeWithSignature("notAFunction()"));
        assertFalse(ok);
        assertEq(ret.length, 0);
    }

    //----------------------------------------------------------------------------------------------
    // Zero and limit guards
    //----------------------------------------------------------------------------------------------

    function testZeroAmountRequestsRevert() public {
        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.requestDeposit(0, controller, controller);

        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.requestRedeem(0, controller, controller);
        vm.stopPrank();
    }

    /// @dev A claim above what is claimable must revert rather than no-op.
    function testClaimingWithNothingClaimableReverts() public {
        _requestDeposit(1_000e6);

        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver, controller);

        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.mint(1_000e18, receiver, controller);
        vm.stopPrank();
    }

    function testRedeemClaimBeyondTheLimitReverts() public {
        vm.prank(controller);
        v.requestRedeem(1_000e18, controller, controller);

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(vault)).revokeShares(1, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(1, 1_000e6, 1_000e18);
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.withdraw(1_000e6 + 1, receiver, controller);
    }

    /// @dev Folding what is not there does nothing, so a keeper's batch survives a claim landing first
    function testFoldingAnEmptyContributionIsANoOp() public {
        v.foldRequest(1, controller);
        v.foldRequest(1, controller);
    }

    function testFoldingACompletedPositionTwiceIsANoOp() public {
        _settleDeposit(1_000e6, 1_000e18);
        v.foldRequest(1, controller);
        v.foldRequest(1, controller);

        vm.prank(controller);
        assertEq(v.mint(1_000e18, receiver, controller), 1_000e6, "the slice was folded once");
    }

    function testTransferOfAForeignRequestIdReverts() public {
        uint256 foreign = VaultRequestIdLib.from(outsider, 1).raw();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidRequestId.selector);
        v.transferDepositRequest(foreign, controller, receiver);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidRequestId.selector);
        v.transferRedeemRequest(foreign, controller, receiver);
    }

    /// @dev A request id that names this vault but a bucket on the other side is not this side's
    ///      request, and the views must say so rather than reading the wrong bucket.
    function testPendingViewsIgnoreTheOtherSideAndForeignVaults() public {
        uint96 localId = _requestDeposit(1_000e6);
        uint256 id = VaultRequestIdLib.from(address(vault), localId).raw();

        assertEq(v.pendingDepositRequest(id, controller), 1_000e6, "the deposit side sees it");
        assertEq(v.pendingRedeemRequest(id, controller), 0, "the redeem side does not");
        assertEq(
            v.pendingDepositRequest(VaultRequestIdLib.from(outsider, localId).raw(), controller),
            0,
            "and neither does another vault's id"
        );
    }

    //----------------------------------------------------------------------------------------------
    // Local id allocation
    //----------------------------------------------------------------------------------------------

    /// @dev Local ids are the vault's to hand out: a policy names buckets by keys, so whatever key it answers, the
    ///      bucket is one the vault allocated, counting up from 1, and the zero sentinel of the ERC-7540 aggregate views
    ///      is never one.
    function testAPolicysKeyNeverPicksTheId(bytes32 key) public {
        vm.assume(key != 0);
        Vault rogue = _vaultWithPolicy(address(new FixedKeyPolicy(key)));

        vm.prank(controller);
        uint256 requestId = IAsyncVault(address(rogue)).requestDeposit(1_000e6, controller, controller);
        assertEq(_localIdOf(requestId), 1, "the vault's first id");
        assertEq(IAsyncVault(address(rogue)).bucketOf(key, true), 1, "under the policy's key");
        assertEq(IAsyncVault(address(rogue)).keyOf(1), key, "which the id maps back to, unbatched too");
    }

    /// @dev An unbatched bucket is its owner's, so once it moves to another controller the owner's key stops naming it:
    ///      the sender's next request opens a bucket of its own, rather than reverting against the recipient's.
    function testATransferredUnbatchedBucketReleasesTheSendersKey() public {
        Vault keyed = _vaultWithPolicy(address(new ControllerKeyPolicy(false)));
        bytes32 key = CastLib.toBytes32(controller);
        address recipient = makeAddr("recipient");

        vm.startPrank(controller);
        uint256 requestId = keyed.requestDeposit(1_000e6, controller, controller);
        keyed.transferDepositRequest(requestId, controller, recipient);
        assertEq(keyed.bucketOf(key, true), 0, "the key no longer names the moved bucket");
        assertEq(keyed.keyOf(1), key, "which still maps back to the key it was opened under");

        uint256 next = keyed.requestDeposit(500e6, controller, controller);
        vm.stopPrank();
        assertEq(_localIdOf(next), 2, "the sender's next request opens a bucket of its own");
        assertEq(keyed.bucketOf(key, true), 2, "now under the key");
        assertEq(keyed.pendingDepositRequest(0, recipient), 1_000e6, "and the moved bucket stays the recipient's");
        assertEq(keyed.pendingDepositRequest(0, controller), 500e6, "beside the sender's own");
    }

    /// @dev A batch is sent once its policy reports its key closed, so a batching policy must name one: the zero key
    ///      would open a batch nothing could close.
    function testABatchingPolicyCannotAnswerTheZeroKey() public {
        Vault zeroBatch = _vaultWithPolicy(address(new ControllerKeyPolicy(true)));
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ZeroBatchKey.selector);
        zeroBatch.requestDeposit(1_000e6, controller, controller);
    }

    /// @dev An unbatched bucket has one owner, whose position the vault folds as it settles, so a non-batching policy
    ///      cannot put a second controller in it: the bucket was sent with its owner's request and is sealed.
    function testAnUnbatchedRequestCannotJoinAnotherControllersBucket() public {
        Vault rogue = _vaultWithPolicy(address(new FixedKeyPolicy(bytes32(uint256(1)))));
        vm.prank(controller);
        IAsyncVault(address(rogue)).requestDeposit(1_000e6, controller, controller);

        address other = makeAddr("otherController");
        asset.mint(other, 1_000e6);
        vm.startPrank(other);
        asset.approve(address(rogue), 1_000e6);
        vm.expectRevert(IVaultErrors.BucketSealed.selector);
        IAsyncVault(address(rogue)).requestDeposit(1_000e6, other, other);
        vm.stopPrank();
    }

    /// @dev The counter only advances when the policy takes what it was offered, which is what lets a
    ///      grouping policy keep extending one bucket without burning an id per request.
    function testTheCounterOnlyAdvancesOnAFreshBucket() public {
        assertEq(_requestDeposit(1_000e6), 1);
        assertEq(_requestDeposit(1_000e6), 2, "per-request policy takes a fresh id every time");

        Vault grouped = _vaultWithPolicy(address(new PerInvestorPolicy()));
        vm.startPrank(controller);
        assertEq(_localIdOf(IAsyncVault(address(grouped)).requestDeposit(1_000e6, controller, controller)), 1);
        assertEq(
            _localIdOf(IAsyncVault(address(grouped)).requestDeposit(1_000e6, controller, controller)),
            1,
            "the reused bucket did not consume the next id"
        );
        assertEq(
            _localIdOf(IAsyncVault(address(grouped)).requestRedeem(1_000e18, controller, controller)),
            2,
            "so the other side gets it"
        );
        vm.stopPrank();
    }

    function _localIdOf(uint256 requestId) internal pure returns (uint96) {
        return uint96(requestId);
    }

    function _vaultWithPolicy(address policy) internal returns (Vault) {
        return _vaultWith(policy, instantPolicy);
    }

    function _vaultWith(address policy, address instant) internal returns (Vault) {
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
                    instantPolicy: IInstantPolicy(instant),
                    requestPolicy: IRequestPolicy(policy),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );
    }

    //----------------------------------------------------------------------------------------------
    // Settlement fold
    //----------------------------------------------------------------------------------------------

    /// @dev Nothing is claimed or folded here: the credit in the stored ledger can only have come from the vault
    ///      folding the unbatched bucket inside the callback.
    function testTheEagerFoldRunsInsideTheSettlement() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        uint256 credited = v.claimableMint(controller);
        assertEq(credited, 1_000e18, "folded during the callback");
    }

    //----------------------------------------------------------------------------------------------
    // Fold hygiene
    //----------------------------------------------------------------------------------------------

    /// @dev A fold that completes a contribution has to drop the entry from the horizon.
    ///      `PerInvestorPolicy` keys local ids by controller and reuses them after retirement, so a
    ///      stale entry plus the next request's push puts the same id in the window twice, after which
    ///      the views walk one contribution twice and over-report the claim, making a claim at the
    ///      reported max revert.
    function testACompletingFoldLeavesNoStaleCursorEntry() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        // The settlement's fold completes the contribution through the same path a keeper's `foldRequest`
        // takes, so the horizon is maintained there or nowhere.
        vm.prank(controller);
        v.mint(1_000e18, receiver, controller);

        // A second cycle on the same position. With a stale entry left behind, this one would be
        // counted twice by every view that walks the horizon.
        uint96 second = _requestDeposit(2_000e6);
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(second, 2_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(second, 2_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(second, 2_000e6, 2_000e18);
        vm.stopPrank();

        assertEq(v.maxMint(controller), 2_000e18, "counted once");
        assertEq(v.maxDeposit(controller), 2_000e6, "counted once");

        // ERC-4626: a claim at the reported max must succeed.
        uint256 claimable = v.maxMint(controller);
        vm.prank(controller);
        v.mint(claimable, receiver, controller);
    }

    /// @dev A stranger cannot reuse a completed id, as `PerInvestorPolicy` would by keying buckets by controller, to
    ///      put a position on the controller: on a vault with both lanes, crediting a controller the caller does not
    ///      act for needs a sponsor the instant policy accepts, so the controller's instant lane stays open.
    function testAStrangerCannotReuseACompletedIdToHoldTheLane() public {
        Vault grouped = _vaultWithPolicy(address(new PerInvestorPolicy()));
        vm.prank(controller);
        uint96 localId = uint96(grouped.requestDeposit(1_000e6, controller, controller));
        vm.startPrank(router);
        IVaultDepositCallbacks(address(grouped)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(grouped)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(grouped)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();
        grouped.foldRequest(localId, controller);

        address attacker = makeAddr("attacker");
        vm.mockCall(
            instantPolicy,
            abi.encodeCall(IInstantPolicy.canCredit, (address(grouped), attacker, controller)),
            abi.encode(false)
        );
        vm.prank(attacker);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        grouped.requestDeposit(1, controller, attacker);

        vm.prank(controller);
        grouped.mint(1_000e18, receiver, controller);
        assertGt(grouped.maxDeposit(controller), 0, "the instant lane stays open");
    }

    /// @dev "A request credits a controller only through that controller, its operator or a sponsor, on a vault with
    ///      both lanes": a stranger the instant policy does not accept is refused there, and goes through on an
    ///      async-only vault, where nothing routes on a pending position.
    function testAStrangerCreditsAnotherControllerOnlyWithoutAnInstantLane() public {
        address stranger = makeAddr("stranger");
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(false));

        vm.prank(stranger);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.requestDeposit(1_000e6, controller, stranger);
        vm.prank(stranger);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.requestRedeem(1_000e18, controller, stranger);

        Vault asyncOnly = _vaultWith(address(requestPolicy), address(0));
        vm.prank(stranger);
        asyncOnly.requestDeposit(1_000e6, controller, stranger);
        assertEq(asyncOnly.pendingDepositRequest(0, controller), 1_000e6, "credited without consent, as in v1");
    }

    /// @dev The zero address has no caller and can approve no operator, so on a vault with both lanes only a
    ///      sponsor's error could credit it.
    function testOnAnInstantVaultTheZeroAddressNeedsASponsor() public {
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(false));
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.requestDeposit(1_000e6, address(0), controller);
    }

    /// @dev On a vault with both lanes an unasked-for position would hold its recipient's lane closed, so a transfer to
    ///      a recipient the caller does not act for needs a sponsor.
    function testOnAnInstantVaultATransferNeedsTheRecipientsConsent() public {
        address recipient = makeAddr("recipient");
        vm.prank(controller);
        uint256 requestId = v.requestDeposit(1_000e6, controller, controller);
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.canCredit.selector), abi.encode(false));

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.NotSponsor.selector);
        v.transferDepositRequest(requestId, controller, recipient);

        vm.prank(recipient);
        v.setOperator(controller, true);
        vm.prank(controller);
        v.transferDepositRequest(requestId, controller, recipient);
        assertEq(v.pendingDepositRequest(0, recipient), 1_000e6, "the recipient agreed");
    }

    /// @dev Without an instant lane an unasked-for position costs its recipient nothing, so a transfer is a plain
    ///      ERC-8161 push: no consent from the recipient and no sponsor.
    function testOnAnAsyncVaultATransferIsAPlainPush() public {
        Vault asyncOnly = _vaultWith(address(requestPolicy), address(0));
        address recipient = makeAddr("recipient");
        vm.prank(controller);
        uint256 requestId = asyncOnly.requestDeposit(1_000e6, controller, controller);

        vm.prank(controller);
        asyncOnly.transferDepositRequest(requestId, controller, recipient);
        assertEq(asyncOnly.pendingDepositRequest(0, recipient), 1_000e6, "pushed to a recipient that never asked");
    }

    /// @dev Floor-rounded slices cannot credit a shared bucket's contributors the exact amounts they
    ///      put in. The remainder is retired on the completing fold; left behind, it keeps the
    ///      controller's pending non-zero forever, and the routing predicate reads that as still-async
    ///      and closes the instant lane for good.
    function testFloorRoundingRemainderDoesNotPinTheControllerInAsyncMode() public {
        uint96 localId = _requestDeposit(3);

        // Fill 2 of the 3 and cancel the rest, so the bucket settles fully while the slices floor.
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 2);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 2);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 2, 2);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 1, 1);
        vm.stopPrank();

        assertEq(v.pendingDepositRequest(0, controller), 0, "the request is fully settled");

        // Which is what keeps the instant lane open for them afterwards.
        assertGt(v.maxDeposit(controller), 0, "the controller is out of async mode");
    }

    /// @dev A shared window whose slices floor to zero in one unit only. A redeem slice is credited
    ///      in assets: one that floors to zero shares with assets left must still pay out, or those
    ///      assets stay reserved for good while `maxWithdraw` keeps reporting them. A third party can
    ///      push the one share-wei that makes the slice.
    function testADustRedeemSliceIsCreditedInAssets() public {
        IAsyncVault grouped = IAsyncVault(address(_perPeriodVault()));
        address other = makeAddr("other");
        uint96 localId = _sharedWindow(grouped, other, false);

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(grouped)).revokeShares(localId, 10, 1);
        IVaultRedeemCallbacks(address(grouped)).fulfillRedeemRequest(localId, 10, 1);
        vm.stopPrank();

        assertEq(grouped.maxWithdraw(controller), 2, "the slice is 0 shares and 2 assets");

        vm.expectEmit(address(grouped));
        emit IVaultEvents.RedeemClaimable(_requestIdOf(grouped, localId), controller, 2, 0);
        vm.prank(controller);
        grouped.withdraw(2, receiver, controller);
        uint256 left = grouped.claimableWithdraw(controller);
        assertEq(left, 0, "paid in full");
    }

    /// @dev The deposit-side mirror: a slice of shares with no assets is credited, so it is announced.
    function testADustDepositSliceEmitsDepositClaimable() public {
        IAsyncVault grouped = IAsyncVault(address(_perPeriodVault()));
        address other = makeAddr("other");
        uint96 localId = _sharedWindow(grouped, other, true);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(grouped)).approveDeposits(localId, 1);
        IVaultDepositCallbacks(address(grouped)).issueShares(localId, 10);
        IVaultDepositCallbacks(address(grouped)).fulfillDepositRequest(localId, 1, 10);
        vm.stopPrank();

        assertEq(grouped.maxMint(controller), 2, "the slice is 2 shares and 0 assets");

        vm.expectEmit(address(grouped));
        emit IVaultEvents.DepositClaimable(_requestIdOf(grouped, localId), controller, 0, 2);
        grouped.foldRequest(localId, controller);
        assertEq(grouped.maxMint(controller), 2, "the fold credits what the view reported");
    }

    /// @dev The redeem ledger ignores a slice with shares but no assets, so the unfolded views must too:
    ///      counted in `maxRedeem`, a redeem of the reported max would exceed the ledger once folded.
    function testARedeemSliceWithoutAssetsIsNotReportedAsClaimable() public {
        IAsyncVault grouped = IAsyncVault(address(_perPeriodVault()));
        address other = makeAddr("other");

        vm.prank(controller);
        uint96 first = uint96(grouped.requestRedeem(100, controller, controller));
        vm.warp(block.timestamp + 1 days);
        grouped.flushRequest(first);
        vm.startPrank(router);
        IVaultRedeemCallbacks(address(grouped)).revokeShares(first, 100, 100);
        IVaultRedeemCallbacks(address(grouped)).fulfillRedeemRequest(first, 100, 100);
        vm.stopPrank();
        grouped.foldRequest(first, controller);

        uint96 localId = _sharedWindow(grouped, other, false);
        vm.startPrank(router);
        IVaultRedeemCallbacks(address(grouped)).revokeShares(localId, 1, 4);
        IVaultRedeemCallbacks(address(grouped)).fulfillRedeemRequest(localId, 1, 4);
        vm.stopPrank();

        uint256 maxRedeem = grouped.maxRedeem(controller);
        assertEq(maxRedeem, 100, "the 1 share slice with no assets is not claimable");
        vm.prank(controller);
        grouped.redeem(maxRedeem, receiver, controller);
        uint256 left = grouped.claimableWithdraw(controller);
        assertEq(left, 0, "paid in full");
    }

    function _perPeriodVault() internal returns (Vault) {
        return _vaultWithPolicy(address(new PerPeriodPolicy(1 days, 0, 0, 0)));
    }

    /// @dev One window, `controller` contributing 1 wei and `other` 3, closed and flushed.
    function _sharedWindow(IAsyncVault grouped, address other, bool isDeposit) internal returns (uint96 localId) {
        vm.prank(controller);
        uint256 requestId = isDeposit
            ? grouped.requestDeposit(1, controller, controller)
            : grouped.requestRedeem(1, controller, controller);
        vm.prank(other);
        uint256 second = isDeposit ? grouped.requestDeposit(3, other, other) : grouped.requestRedeem(3, other, other);
        assertEq(second, requestId, "one shared window");

        localId = uint96(requestId);
        vm.warp(block.timestamp + 1 days);
        grouped.flushRequest(localId);
    }

    function _requestIdOf(IAsyncVault grouped, uint96 localId) internal pure returns (uint256) {
        return VaultRequestIdLib.from(address(grouped), localId).raw();
    }

    //----------------------------------------------------------------------------------------------
    // Capacity views propagate a reverting dependency
    //----------------------------------------------------------------------------------------------

    /// @dev The `max*` views read the instant policy with a plain call (no try/catch in core), so a
    ///      policy that reverts propagates rather than reading as zero. A pool must wire a policy
    ///      whose reads do not revert; the max-view non-revert guarantee is an `n` row in the spec.
    function testARevertingInstantPolicyRevertsTheViews() public {
        vm.mockCallRevert(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantDeposit.selector), "no");
        vm.mockCallRevert(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector), "no");

        vm.expectRevert();
        v.maxDeposit(controller);
        vm.expectRevert();
        v.maxMint(controller);
        vm.expectRevert();
        v.maxWithdraw(controller);
        vm.expectRevert();
        v.maxRedeem(controller);
    }

    /// @dev Same for the action hook: `_isAllowed` calls `checkAction` plainly, so a reverting hook
    ///      reverts the claim views.
    function testARevertingActionHookRevertsTheClaimViews() public {
        vm.prank(controller);
        v.requestRedeem(1_000e18, controller, controller);
        vm.startPrank(router);
        IVaultRedeemCallbacks(address(vault)).revokeShares(1, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(1, 1_000e6, 1_000e18);
        vm.stopPrank();

        assertEq(v.maxWithdraw(controller), 1_000e6, "claimable while the hook allows it");

        vm.mockCallRevert(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), "denied");
        vm.expectRevert();
        v.maxWithdraw(controller);
        vm.expectRevert();
        v.maxRedeem(controller);
    }

    function testPendingRequestHidesInstantCapacity() public {
        assertGt(v.maxDeposit(controller), 0, "instant capacity while idle");

        _requestDeposit(1_000e6);

        assertEq(v.maxDeposit(controller), 0, "an open request takes the controller out of the instant lane");
        assertEq(v.maxMint(controller), 0);
    }

    function testRedeemPendingHidesInstantCapacity() public {
        assertGt(v.maxWithdraw(controller), 0);

        vm.prank(controller);
        v.requestRedeem(1_000e18, controller, controller);

        assertEq(v.maxWithdraw(controller), 0);
        assertEq(v.maxRedeem(controller), 0);
    }

    function testZeroPricesLeaveNoInstantCapacity() public {
        _prices(ZERO, ZERO);

        assertEq(v.maxDeposit(controller), 0);
        assertEq(v.maxMint(controller), 0);
        assertEq(v.maxRedeem(controller), 0);
    }

    function testNoInstantPolicyMeansNoInstantCapacity() public {
        Vault async_ = new Vault(
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
                    instantPolicy: IInstantPolicy(address(0)),
                    requestPolicy: IRequestPolicy(address(requestPolicy)),
                    liquidityRoute: ILiquidityRoute(address(0)),
                    settlementObserver: ISettlementObserver(address(0))
                })
            })
        );

        assertEq(IAsyncVault(address(async_)).maxDeposit(controller), 0);
        assertEq(IAsyncVault(address(async_)).maxMint(controller), 0);
        assertEq(IAsyncVault(address(async_)).maxWithdraw(controller), 0);
        assertEq(IAsyncVault(address(async_)).maxRedeem(controller), 0);
    }

    //----------------------------------------------------------------------------------------------
    // Instant-lane guards
    //----------------------------------------------------------------------------------------------

    /// @dev A rebate with no source to pull it from is rejected: a fee with no recipient is retained, but a
    ///      rebate cannot be paid by nobody.
    function testARebateWithoutASourceIsRejected() public {
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(-1e6), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidFeeRecipient.selector);
        v.deposit(1_000e6, receiver);

        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(-1e6), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidFeeRecipient.selector);
        v.redeem(1_000e18, receiver);
    }

    /// @dev A fee that swallows the whole deposit leaves nothing to convert, so the caller would pay
    ///      for zero shares.
    function testAFeeAtOrAboveTheAmountIsRejected() public {
        _instantFees(int128(1_000e6), 0);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver);

        _instantFees(0, int128(1_000e6));

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.redeem(1_000e18, receiver);
    }

    function testInstantDepositBeyondCapacityIsRejected() public {
        _instantCaps(500e6, 1_000_000e6);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver);
    }

    function testInstantRedeemBeyondCapacityIsRejected() public {
        _instantCaps(1_000_000e6, 500e6);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.redeem(1_000e18, receiver);
    }

    /// @dev A zero share price passes the registry's validity check (validity is "notified at least
    ///      once") and would convert any share amount to zero assets, so minting must refuse it
    ///      rather than hand out shares for nothing.
    function testZeroPricesBlockTheInstantLane() public {
        _prices(ZERO, ZERO);

        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.deposit(1_000e6, receiver);

        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.mint(1_000e18, receiver);

        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.redeem(1_000e18, receiver);
        vm.stopPrank();
    }

    /// @dev The policy's fee is the one signed quantity in the vault. `int128.min` cannot be negated, so it reverts
    ///      rather than wrapping to itself, and `int128.max` is a charge no trade can pay: none of the four instant
    ///      entrypoints ever takes either through.
    function testExtremeSignedFeesRevertInsteadOfWrapping() public {
        _instantCaps(type(uint128).max, type(uint128).max);

        _instantFees(type(int128).min, type(int128).min);
        vm.startPrank(controller);
        vm.expectRevert(stdError.arithmeticError);
        v.deposit(1_000e6, receiver);
        vm.expectRevert(stdError.arithmeticError);
        v.mint(1_000e18, receiver);
        vm.expectRevert(stdError.arithmeticError);
        v.redeem(1_000e18, receiver);
        vm.expectRevert(stdError.arithmeticError);
        v.withdraw(1_000e6, receiver);
        vm.stopPrank();

        _instantFees(type(int128).max, type(int128).max);
        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.mint(1_000e18, receiver);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.redeem(1_000e18, receiver);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.withdraw(1_000e6, receiver);
        vm.stopPrank();
    }

    function testMintGuards() public {
        // A rebate with no source, on the mint entry point rather than deposit.
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantDeposit.selector),
            abi.encode(int128(-1e6), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantDeposit.selector), "");
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidFeeRecipient.selector);
        v.mint(1_000e18, receiver);

        // Minting beyond the capacity, where the fee is charged on top of the shares' asset value.
        _instantFees(0, 0);
        _instantCaps(500e6, 1_000_000e6);
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.mint(1_000e18, receiver);

        // Minting nothing charges nothing: the asset leg rounds up, so only a zero share amount
        // reaches a zero charge, and it must revert rather than emit an empty deposit.
        _instantCaps(1_000_000e6, 1_000_000e6);
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.mint(0, receiver);
    }

    function testWithdrawGuards() public {
        vm.mockCall(
            instantPolicy,
            abi.encodeWithSelector(IInstantPolicy.quoteInstantRedeem.selector),
            abi.encode(int128(-1e6), address(0))
        );
        vm.mockCall(instantPolicy, abi.encodeWithSelector(IInstantPolicy.onInstantRedeem.selector), "");
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidFeeRecipient.selector);
        v.withdraw(1_000e6, receiver);

        _instantFees(0, 0);
        _instantCaps(1_000_000e6, 500e6);
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.withdraw(1_000e6, receiver);

        _instantCaps(1_000_000e6, 1_000_000e6);
        _prices(ONE, ZERO);
        vm.prank(controller);
        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.withdraw(1_000e6, receiver);
    }

    /// @dev Redeeming shares worth zero assets would consume nothing and pay nothing, so it reverts
    ///      rather than no-opping past the limit check.
    function testAsyncRedeemOfDustReverts() public {
        vm.prank(controller);
        v.requestRedeem(1_000e18, controller, controller);

        vm.startPrank(router);
        IVaultRedeemCallbacks(address(vault)).revokeShares(1, 1_000e6, 1_000e18);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(1, 1_000e6, 1_000e18);
        vm.stopPrank();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.redeem(0, receiver, controller);
    }

    /// @dev Claiming nothing reverts on every claim path, not only where a zero converted leg would
    ///      catch it, so no claim emits an empty event.
    function testAsyncClaimOfNothingReverts() public {
        // Pending requests on both sides route the claims to the async lane.
        vm.startPrank(controller);
        v.requestDeposit(1_000e6, controller, controller);
        v.requestRedeem(1_000e18, controller, controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.mint(0, receiver, controller);

        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.withdraw(0, receiver, controller);
        vm.stopPrank();
    }

    /// @dev Redeeming or withdrawing nothing must revert rather than emit an empty exit: both legs
    ///      round up, so only a zero request reaches a zero payout.
    function testInstantExitOfNothingReverts() public {
        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.redeem(0, receiver);

        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.withdraw(0, receiver);
        vm.stopPrank();
    }

    //----------------------------------------------------------------------------------------------
    // Cancellation and routing
    //----------------------------------------------------------------------------------------------

    /// @dev A cancelled redeem leaves the shares parked in the escrow, so they come back through
    ///      the deposit side — a standard integrator recovers them with `mint`, having never called a
    ///      cancellation method.
    function testCancelledRedeemIsClaimedThroughTheDepositSide() public {
        vm.prank(controller);
        uint256 requestId = v.requestRedeem(1_000e18, controller, controller);

        vm.expectEmit(true, true, false, true);
        emit IVaultEvents.CancelRedeemClaimable(requestId, controller, 1_000e18);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(uint96(requestId), 1_000e18, 1_000e18);

        assertEq(v.maxMint(controller), 1_000e18, "the cancelled shares are claimable via mint");
        assertEq(v.pendingRedeemRequest(0, controller), 0, "and nothing is pending any more");
    }

    /// @dev A retained cancellation fee is the gross/net difference: it accrues to the pool, so the
    ///      investor gets back less than was retired.
    function testACancellationFeeIsRetained() public {
        vm.prank(controller);
        uint256 requestId = v.requestRedeem(1_000e18, controller, controller);

        // The retained 10 shares are burnt out of the escrow, so they accrue to the holders at once.
        vm.expectCall(spoke, abi.encodeWithSelector(ISpoke.revoke.selector, POOL, SC, uint128(10e18)));
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(uint96(requestId), 1_000e18, 990e18);

        assertEq(v.maxMint(controller), 990e18, "the investor claims the net amount");
        assertEq(v.pendingRedeemRequest(0, controller), 0, "while the gross retires the request");
    }

    /// @dev The 2-arg entry points take the async branch whenever anything is pending or claimable,
    ///      so a controller mid-request never accidentally funds a fresh instant deposit.
    function testTwoArgEntryPointsClaimWhileARequestIsOpen() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        assertEq(v.maxMint(controller), 1_000e18, "claimable, not instant capacity");

        vm.prank(controller);
        uint256 shares = v.deposit(400e6, receiver);
        assertEq(shares, 400e18, "the 2-arg deposit claimed rather than depositing");

        vm.prank(controller);
        uint256 assets = v.mint(600e18, receiver);
        assertEq(assets, 600e6, "and so did the 2-arg mint");
    }

    /// @dev The deposit-side twin of the redeem check: a share token that would refuse the escrow to
    ///      controller leg hides the claim from the capacity views, so `maxDeposit`/`maxMint` agree
    ///      with what a claim would do.
    function testARefusingShareTokenHidesTheDepositClaim() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        assertEq(v.maxDeposit(controller), 1_000e6);

        share.setAllowed(false);
        assertEq(v.maxDeposit(controller), 0, "hidden while the token refuses");
        assertEq(v.maxMint(controller), 0);
    }

    /// @dev A deposit claim delivered to another receiver is an escrow to receiver transfer, which the transfer hook
    ///      sees without the controller. The vault therefore asks `Entry` of the controller, and of the receiver from
    ///      the controller, which is where a hook can relate the two, and a hook that refuses the controller stops
    ///      the claim.
    function testADepositClaimChecksTheControllerAndItsReceiver() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        // The claimed position moves from the controller to the receiver, another account
        RoleCheck[] memory checks = new RoleCheck[](2);
        checks[0] = RoleCheck(Role.Entry, address(0), controller, 500e6, 500e18, Effect.Neutral);
        checks[1] = RoleCheck(Role.Entry, controller, receiver, 500e6, 500e18, Effect.Moves);
        vm.expectCall(actionHook, abi.encodeCall(IRoleHook.onRoles, (address(share), checks)), 1);
        vm.prank(controller);
        v.deposit(500e6, receiver, controller);

        share.setHook(address(new RoleRefusingHook(Role.Entry, controller)));
        vm.prank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.deposit(500e6, receiver, controller);
    }

    /// @dev The role checks of a claim run before the ledger is debited, as the max views and `checkRoles` read it, so a
    ///      hook that reads the controller's claimable shares sees the claim still in it.
    function testAClaimChecksSeeTheClaimableBeforeItIsDebited() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        ClaimableProbeHook probe = new ClaimableProbeHook(v, controller);
        share.setHook(address(probe));

        vm.startPrank(controller);
        v.deposit(500e6, receiver, controller);
        v.mint(250e18, receiver, controller);
        vm.stopPrank();

        assertEq(probe.seen(0), 1_000e18, "deposit claim");
        assertEq(probe.seen(1), 500e18, "mint claim");
    }

    /// @dev A share token with no hook has no vault-action gating at all, and the views must not
    ///      treat the missing hook as a refusal.
    function testNoShareHookMeansNoGating() public {
        share.setHook(address(0));
        // The previously set hook would refuse everything, so a pass proves it is no longer consulted.
        vm.mockCallRevert(actionHook, abi.encodeWithSelector(IRoleHook.onRoles.selector), "consulted");
        vm.mockCall(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), abi.encode(false));
        IAsyncVault open = IAsyncVault(address(vault));

        uint96 localId = _requestDeposit(1_000e6);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(open)).approveDeposits(localId, 1_000e6);
        IVaultDepositCallbacks(address(open)).issueShares(localId, 1_000e18);
        IVaultDepositCallbacks(address(open)).fulfillDepositRequest(localId, 1_000e6, 1_000e18);
        vm.stopPrank();

        assertEq(open.maxDeposit(controller), 1_000e6, "no hook, no refusal");

        vm.prank(controller);
        open.deposit(1_000e6, receiver, controller);
    }

    /// @dev Buckets settle in whatever order the hub fulfils them. A completed bucket is swapped to
    ///      the front so the fold can advance past it without a stuck bucket pinning later ones.
    function testFoldCompactsBucketsSettledOutOfOrder() public {
        uint96 first = _requestDeposit(1_000e6);
        uint96 second = _requestDeposit(2_000e6);
        uint96 third = _requestDeposit(3_000e6);
        assertTrue(first != second && second != third);

        // Only the middle request settles, so the fold has to skip a still-open bucket ahead of it.
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(second, 2_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(second, 2_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(second, 2_000e6, 2_000e18);
        vm.stopPrank();

        assertEq(v.maxMint(controller), 2_000e18, "only the settled bucket is claimable");

        // Now settle the first as well; both must fold, and the earlier one is no longer at the head.
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(first, 1_000e6);
        IVaultDepositCallbacks(address(vault)).issueShares(first, 1_000e18);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(first, 1_000e6, 1_000e18);
        vm.stopPrank();

        assertEq(v.maxMint(controller), 3_000e18, "both settled buckets folded");
        assertEq(v.pendingDepositRequest(0, controller), 3_000e6, "the third is still outstanding");

        vm.prank(controller);
        v.mint(3_000e18, receiver, controller);
        assertEq(v.maxMint(controller), 0);
    }

    /// @dev Dust that converts to zero shares would take the caller's asset and mint nothing.
    function testADepositTooSmallToMintAShareIsRejected() public {
        // One unit of a 6-decimal asset against a share worth 1e13 of them converts to zero shares.
        _prices(ONE, D18.wrap(1e31));

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.deposit(1, receiver);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 claimable views
    //----------------------------------------------------------------------------------------------

    function _settleDeposit(uint128 assets, uint128 shares) internal {
        uint96 localId = _requestDeposit(assets);
        vm.startPrank(router);
        IVaultDepositCallbacks(address(vault)).approveDeposits(localId, assets);
        IVaultDepositCallbacks(address(vault)).issueShares(localId, shares);
        IVaultDepositCallbacks(address(vault)).fulfillDepositRequest(localId, assets, shares);
        vm.stopPrank();
    }

    function _settleRedeem(uint128 shares, uint128 assets) internal {
        vm.prank(controller);
        uint256 requestId = v.requestRedeem(shares, controller, controller);
        vm.startPrank(router);
        IVaultRedeemCallbacks(address(vault)).revokeShares(uint96(requestId), assets, shares);
        IVaultRedeemCallbacks(address(vault)).fulfillRedeemRequest(uint96(requestId), assets, shares);
        vm.stopPrank();
    }

    /// @dev A caller with a claim previews the claim, not the instant lane: the four previews equal what the
    ///      2-argument call then pays, and a caller without one still gets the oracle quote. The fill here is at
    ///      twice the oracle's share count, so the two readings differ.
    function testPreviewsQuoteTheClaimForACallerWithOne() public {
        _settleDeposit(1_000e6, 2_000e18);

        vm.startPrank(controller);
        uint256 shares = v.previewDeposit(500e6);
        assertEq(shares, 1_000e18, "a claimant is quoted the fill price");
        assertEq(v.previewMint(1_000e18), 500e6, "and so is the exact-shares quote");
        uint256 minted = v.deposit(500e6, receiver);
        assertEq(minted, shares, "the preview is the claim");
        vm.stopPrank();

        assertEq(v.previewDeposit(500e6), 500e18, "a caller with nothing to claim is quoted the instant lane");
    }

    /// @dev The redeem-side twin: a redemption filled at half the oracle's assets per share.
    function testRedeemPreviewsQuoteTheClaimForACallerWithOne() public {
        _settleDeposit(1_000e6, 1_000e18);
        vm.prank(controller);
        v.deposit(1_000e6, controller, controller);
        _settleRedeem(1_000e18, 500e6);

        vm.startPrank(controller);
        uint256 assets = v.previewRedeem(400e18);
        assertEq(assets, 200e6, "a claimant is quoted the fill price");
        assertEq(v.previewWithdraw(200e6), 400e18, "and so is the exact-assets quote");
        assertEq(v.redeem(400e18, receiver), assets, "the preview is the claim");
        vm.stopPrank();
    }

    /// @dev The policy is told who a preview is for, so a fee that depends on the trader can be quoted as the trade
    ///      will charge it. A preview names no receiver, so the asker stands in for both.
    function testPreviewsAskThePolicyForTheCaller() public {
        vm.expectCall(
            instantPolicy,
            abi.encodeCall(IInstantPolicy.quoteInstantDeposit, (address(vault), outsider, outsider, 1e6, false))
        );
        vm.prank(outsider);
        v.previewDeposit(1e6);

        vm.expectCall(
            instantPolicy,
            abi.encodeCall(IInstantPolicy.quoteInstantRedeem, (address(vault), outsider, outsider, 1e6, true))
        );
        vm.prank(outsider);
        v.previewWithdraw(1e6);
    }

    /// @dev A claim takes refunded shares first, which carry no assets, then filled ones pro-rata, and the preview
    ///      prices the same split.
    function testPreviewMintPricesOnlyTheFilledShares() public {
        _settleDeposit(1_000e6, 1_000e18);
        vm.prank(controller);
        uint256 requestId = v.requestRedeem(400e18, controller, controller);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(uint96(requestId), 400e18, 400e18);

        vm.startPrank(controller);
        assertEq(v.previewMint(400e18), 0, "refunded shares cost no assets");
        uint256 assets = v.previewMint(500e18);
        assertEq(assets, 100e6, "only the 100 filled shares are priced");
        assertEq(v.mint(500e18, receiver), assets, "the preview is the claim");
        vm.stopPrank();
    }

    /// @dev The redeem-side twin: refunded assets come first and carry no shares.
    function testPreviewWithdrawPricesOnlyTheFilledAssets() public {
        uint96 localId = _requestDeposit(1_000e6);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 1_000e6, 1_000e6);
        _settleRedeem(500e18, 250e6);

        vm.startPrank(controller);
        assertEq(v.previewWithdraw(1_000e6), 0, "refunded assets cost no shares");
        uint256 shares = v.previewWithdraw(1_100e6);
        assertEq(shares, 200e18, "only the 100 filled assets are priced, rounded up");
        assertEq(v.previewRedeem(100e18), 50e6, "and redeem prices the shares at the fill");
        assertEq(v.withdraw(1_100e6, receiver), shares, "the preview is the claim");
        vm.stopPrank();
    }

    /// @dev A claim is priced from the ledger, so a claimant's previews hold while the oracle refuses a price; a
    ///      caller on the instant lane has no price to quote and is refused.
    function testAClaimantsPreviewsDoNotNeedAPrice() public {
        _settleDeposit(1_000e6, 2_000e18);
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, false));

        vm.prank(controller);
        assertEq(v.previewDeposit(500e6), 1_000e18, "quoted from the ledger");

        vm.prank(outsider);
        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.previewDeposit(500e6);
    }

    /// @dev A caller whose only claim is a refund has no filled position to price, so the previews that need one
    ///      refuse as the calls do, and the ones that only count refunds quote nothing.
    function testPreviewsRefuseWhereTheClaimHasNothingFilledToPrice() public {
        // Refunded shares only: a cancelled redemption
        vm.prank(controller);
        uint256 requestId = v.requestRedeem(400e18, controller, controller);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(uint96(requestId), 400e18, 400e18);

        vm.startPrank(controller);
        assertEq(v.previewMint(400e18), 0, "the refund is free");
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.previewMint(401e18);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.previewDeposit(1e6);
        vm.stopPrank();
    }

    /// @dev The same on the redeem side: a refunded deposit leaves assets with no shares behind them.
    function testRedeemPreviewsRefuseWhereTheClaimHasNothingFilledToPrice() public {
        uint96 localId = _requestDeposit(1_000e6);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 1_000e6, 1_000e6);

        vm.startPrank(controller);
        assertEq(v.previewWithdraw(1_000e6), 0, "the refund burns no shares");
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.previewWithdraw(1_001e6);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.previewRedeem(1e18);
        vm.stopPrank();
    }

    /// @dev The horizon keeps an entry in 64 bits, so the vault stops issuing local ids past 2^64 - 1. Ids count up
    ///      one bucket at a time, so it is not a limit anything reaches.
    function testALocalIdBeyondWhatTheHorizonKeepsIsRefused() public {
        uint256 nonceSlot = 3;
        vm.store(address(vault), bytes32(nonceSlot), bytes32(uint256(type(uint64).max) - 1));

        vm.prank(controller);
        v.requestDeposit(1e6, controller, controller);

        vm.prank(controller);
        vm.expectRevert(stdError.arithmeticError);
        v.requestDeposit(1e6, controller, controller);
    }

    /// @dev A caller with a pending request of its own and nothing claimable has no claim to quote: the preview
    ///      refuses as the call would, instead of quoting a price the call would not use.
    function testPreviewsRefuseForACallerWhoseRequestIsStillPending() public {
        _requestDeposit(1_000e6);

        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.previewDeposit(1e6);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1e6, receiver);
        vm.stopPrank();
    }

    /// @dev Each side reports in the unit ERC-7540 names for it: assets on the deposit side, shares on
    ///      the redeem side, both derived from what the hub actually fulfilled.
    function testClaimableViewsReportTheFulfilledLedger() public {
        assertEq(v.claimableDepositRequest(0, controller), 0, "nothing fulfilled yet");

        _settleDeposit(1_000e6, 1_000e18);
        assertEq(v.claimableDepositRequest(0, controller), 1_000e6, "assets made claimable");
        assertEq(v.claimableDepositRequest(0, controller), v.maxDeposit(controller), "agrees with maxDeposit");

        vm.prank(controller);
        v.deposit(1_000e6, receiver, controller);
        assertEq(v.claimableDepositRequest(0, controller), 0, "consumed by the claim");

        _settleRedeem(500e18, 500e6);
        assertEq(v.claimableRedeemRequest(0, controller), 500e18, "shares made claimable");
        assertEq(v.claimableRedeemRequest(0, controller), v.maxRedeem(controller), "agrees with maxRedeem");
    }

    /// @dev The two views used to disagree: the deposit side computed the ledger, the redeem side
    ///      delegated to `maxRedeem` and so fell through to instant capacity, reporting a claimable
    ///      redeem *request* for a controller who had never made one.
    function testClaimableViewsDoNotFallThroughToInstantCapacity() public view {
        assertGt(v.maxDeposit(controller), 0, "the instant lane is open");
        assertGt(v.maxRedeem(controller), 0);

        assertEq(v.claimableDepositRequest(0, controller), 0, "but no deposit request is claimable");
        assertEq(v.claimableRedeemRequest(0, controller), 0, "and no redeem request is either");
    }

    /// @dev What the hub fulfilled is a fact about the request; whether the controller may take
    ///      delivery of it right now is what `max*` answers. So the hook gates one and not the other.
    function testClaimableViewsAreNotGatedByTheShareHook() public {
        _settleDeposit(1_000e6, 1_000e18);
        _settleRedeem(500e18, 500e6);

        vm.mockCall(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), abi.encode(false));
        share.setAllowed(false);

        assertEq(v.maxDeposit(controller), 0, "the claim is blocked");
        assertEq(v.maxRedeem(controller), 0);
        assertEq(v.claimableDepositRequest(0, controller), 1_000e6, "the fulfillment still happened");
        assertEq(v.claimableRedeemRequest(0, controller), 500e18);
    }

    /// @dev ERC-7540 requires the request views not to revert. Keeping the hook and the instant policy
    ///      out of them is what makes that true of a vault whose hook or policy misbehaves.
    function testClaimableViewsSurviveARevertingHookAndPolicy() public {
        _settleDeposit(1_000e6, 1_000e18);
        _settleRedeem(500e18, 500e6);

        vm.mockCallRevert(actionHook, abi.encodeWithSelector(IRoleHook.checkRoles.selector), "denied");
        vm.mockCallRevert(instantPolicy, abi.encodeWithSelector(IInstantPolicy.maxInstantRedeem.selector), "down");

        assertEq(v.claimableDepositRequest(0, controller), 1_000e6);
        assertEq(v.claimableRedeemRequest(0, controller), 500e18);
    }

    /// @dev No routed selector is payable and nothing in the flow sends value here, so the router
    ///      refuses ETH outright rather than stranding it: there is no `receive()` and `fallback()`
    ///      is non-payable.
    function testTheVaultRefusesEth() public {
        vm.deal(controller, 1 ether);

        vm.prank(controller);
        (bool ok,) = address(vault).call{value: 1}("");
        assertFalse(ok, "a plain transfer is refused");

        vm.prank(controller);
        (ok,) = address(vault).call{value: 1}(abi.encodeWithSignature("maxDeposit(address)", controller));
        assertFalse(ok, "and so is a value-carrying call to a routed selector");
    }

    /// @dev A controller whose only claimable is a cancelled deposit has `maxWithdraw > 0` with no
    ///      shares behind it, so it is claimed through `withdraw`, and `redeem` has no shares to take.
    function testARedeemClaimWithNoSharesBehindTheAssetsReverts() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 1_000e6, 1_000e6);

        assertEq(v.maxWithdraw(controller), 1_000e6, "the refund is claimable through the redeem side");
        assertEq(v.claimableRedeemRequest(0, controller), 0, "with no shares behind it, since none were redeemed");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.redeem(1_000e18, receiver, controller);
    }

    /// @dev A cancelled deposit is claimed through the redeem side, so it emits `Withdraw` — with no
    ///      shares, because none were ever issued for it. Integrators reading `Withdraw` as "shares
    ///      burnt" must see zero rather than a number they would double-count.
    function testAClaimOfCancelledDepositAssetsEmitsWithdrawWithNoShares() public {
        uint96 localId = _requestDeposit(1_000e6);

        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 1_000e6, 1_000e6);

        vm.expectEmit();
        emit IERC7575.Withdraw(controller, receiver, controller, 1_000e6, 0);
        vm.prank(controller);
        v.withdraw(1_000e6, receiver, controller);
    }

    //----------------------------------------------------------------------------------------------
    // Price validity and the retained fee
    //----------------------------------------------------------------------------------------------

    /// @dev The capacity views and the executes read one verdict, so a price the executes refuse must
    ///      read as no capacity rather than as capacity that reverts on use. The views were covered;
    ///      the execute's own refusal was not, which left the two halves of that agreement asserted
    ///      only on one side.
    function testAnExecuteAtAPriceTheOracleWillNotVouchForReverts() public {
        vm.mockCall(oracle, abi.encodeWithSelector(IVaultOracle.prices.selector), abi.encode(ONE, ONE, false));

        assertEq(v.maxDeposit(controller), 0, "no capacity is offered");
        assertEq(v.maxRedeem(controller), 0);

        vm.startPrank(controller);

        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.deposit(1_000e6, receiver);

        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.mint(1_000e18, receiver);

        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.redeem(1_000e18, receiver);

        vm.expectRevert(IVaultErrors.InvalidPrice.selector);
        v.withdraw(1_000e6, receiver);

        vm.stopPrank();
    }

    /// @dev The retained fee is bounded by the amount it is taken out of. At or above it the deposit
    ///      would back zero shares while still taking the caller's assets, which is a donation the
    ///      caller did not ask to make.
    function testARetainedLegAtOrAboveTheDepositIsRejected() public {
        _instantRetained(1_000e6);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver);
    }

    /// @dev The redeem-side twin: a retained fee at or above the payout would burn the shares and pay
    ///      out nothing.
    function testARetainedLegAtOrAboveThePayoutIsRejected() public {
        _instantRetained(1_000e6);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsRedeemLimits.selector);
        v.redeem(1_000e18, receiver);
    }

    //----------------------------------------------------------------------------------------------
    // Async mode with nothing yet fulfilled
    //----------------------------------------------------------------------------------------------

    /// @dev The window between requesting and being fulfilled. The controller has nothing claimable
    ///      and the instant lane is wide open, so the routing predicate is the only thing standing
    ///      between them and an instant trade they did not ask for — and it is the one state where it
    ///      cannot lean on `maxMint` being non-zero, but has to walk the horizon.
    function testATwoArgClaimWithARequestInFlightWillNotTradeInstantly() public {
        _requestDeposit(1_000e6);

        assertEq(v.maxMint(controller), 0, "nothing is claimable yet");
        assertEq(v.maxDeposit(controller), 0, "and the instant lane is closed to them");

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ExceedsDepositLimits.selector);
        v.deposit(1_000e6, receiver);

        // The redeem side is untouched by a deposit in flight, so it still trades.
        vm.prank(controller);
        v.redeem(1_000e18, receiver);
    }

    /// @dev The per-request pending view is asked about a controller and an id together, so it has to
    ///      answer for a live bucket the controller has no stake in. Zero, not the bucket's total.
    function testThePerRequestPendingViewReadsZeroForANonContributor() public {
        uint96 localId = _requestDeposit(1_000e6);
        uint256 requestId = _requestId(localId);

        assertEq(v.pendingDepositRequest(requestId, controller), 1_000e6, "the contributor sees their own");
        assertEq(v.pendingDepositRequest(requestId, outsider), 0, "a non-contributor sees nothing");
        assertEq(v.pendingDepositRequest(0, outsider), 0);
    }

    //----------------------------------------------------------------------------------------------
    // Review regressions
    //----------------------------------------------------------------------------------------------

    /// @dev A cancellation credits the net on the opposite side, and only the gross was ever parked
    ///      for the request. A net above it would credit shares or assets that belong to other
    ///      controllers' claims, so the callback refuses it on both sides.
    function testACancellationCannotCreditMoreThanItRetires() public {
        uint96 depositId = _requestDeposit(1_000e6);
        vm.prank(router);
        vm.expectRevert(IVaultErrors.NetExceedsGross.selector);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(depositId, 1_000e6, 1_000e6 + 1);

        uint96 redeemId = _requestRedeem(10e18);
        vm.prank(router);
        vm.expectRevert(IVaultErrors.NetExceedsGross.selector);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(redeemId, 10e18, 110e18);

        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(redeemId, 10e18, 10e18);
        assertEq(v.maxMint(controller), 10e18, "a net equal to the gross is still accepted");
    }

    /// @dev An instant exit is a redeem request and its claim in one call, gated as the caller's `Exit` and the
    ///      receiver's `Payout` from the caller: a holder the hook refuses cannot take the instant lane out, on
    ///      either entrypoint, and the views say so.
    function testAnInstantExitChecksTheExitAndThePayout() public {
        // Both carry the shares burned and the exact payout
        vm.prank(controller);
        uint128 payout = uint128(v.previewRedeem(1_000e18));
        RoleCheck[] memory checks = new RoleCheck[](2);
        checks[0] = RoleCheck(Role.Exit, address(0), controller, payout, 1_000e18, Effect.Shrinks);
        checks[1] = RoleCheck(Role.Payout, controller, receiver, payout, 1_000e18, Effect.Neutral);
        vm.expectCall(actionHook, abi.encodeCall(IRoleHook.onRoles, (address(share), checks)), 1);
        vm.prank(controller);
        v.redeem(1_000e18, receiver);

        share.setHook(address(new RoleRefusingHook(Role.Exit, controller)));
        assertEq(v.maxRedeem(controller), 0, "no instant redeem capacity for a refused requester");
        assertEq(v.maxWithdraw(controller), 0, "nor instant withdraw capacity");

        vm.startPrank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.redeem(1_000e18, controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.withdraw(1_000e6, controller);
        vm.stopPrank();
    }

    /// @dev An instant deposit asks `Entry` of the caller, the payer, so a hook can refuse a payer the share transfer
    ///      hook (which sees only the receiver) would let through.
    function testAnInstantDepositChecksThePayer() public {
        share.setHook(address(new RoleRefusingHook(Role.Entry, controller)));
        assertEq(v.maxDeposit(controller), 0, "no instant deposit capacity for a refused payer");
        assertEq(v.maxMint(controller), 0, "nor instant mint capacity");

        vm.startPrank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.deposit(1e6, receiver);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.mint(1e18, receiver);
        vm.stopPrank();
    }

    /// @dev The claim's transfer leg runs escrow -> receiver, so it never sees the controller unless
    ///      the two coincide. A controller the hook would not let hold the shares cannot route its claim to
    ///      somebody else, itself or through an operator, on any share-paying claim.
    function testARestrictedControllerCannotClaimToAnotherReceiver() public {
        _settleDeposit(1_000e6, 1_000e18);
        address operator = makeAddr("operator");
        vm.prank(controller);
        v.setOperator(operator, true);

        share.setHook(address(new RoleRefusingHook(Role.Entry, controller)));
        assertEq(v.maxMint(controller), 0, "the view already hides the claim");

        vm.startPrank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.deposit(1_000e6, receiver, controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.mint(1_000e18, receiver, controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.mint(1_000e18, receiver);
        vm.stopPrank();

        vm.prank(operator);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.mint(1_000e18, operator, controller);

        share.setHook(address(0));
        vm.prank(controller);
        v.mint(1_000e18, receiver, controller);
    }

    /// @dev A cancelled redeem is claimed through the same deposit-side path, so it is held to the
    ///      same check.
    function testARestrictedControllerCannotMoveCancelledRedeemShares() public {
        uint96 localId = _requestRedeem(1_000e18);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(localId, 1_000e18, 1_000e18);

        share.setHook(address(new RoleRefusingHook(Role.Entry, controller)));
        vm.prank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.mint(1_000e18, receiver, controller);
    }

    /// @dev A refund returns what the controller put in. Back to the controller itself it is gated by `RefundClaim`
    ///      alone, and moves by an authorized transfer that the transfer hook does not see, so a controller that
    ///      lapsed from the memberlist still takes its cancelled redeem shares back.
    function testACancelledRedeemIsRefundedToTheControllerUnderTheRefundAction() public {
        uint96 localId = _requestRedeem(1_000e18);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(localId, 1_000e18, 1_000e18);

        share.setHook(address(new RoleRefusingHook(Role.Entry, controller)));
        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.transferSharesFrom.selector, POOL, SC, escrow, escrow, controller, uint256(1_000e18)
            )
        );
        vm.prank(controller);
        v.mint(1_000e18, controller, controller);
    }

    function testACancelledRedeemRefundIsRefusedWhereTheHookRefusesTheRefundAction() public {
        uint96 localId = _requestRedeem(1_000e18);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(localId, 1_000e18, 1_000e18);

        share.setHook(address(new RoleRefusingHook(Role.Refund, controller)));
        vm.prank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.mint(1_000e18, controller, controller);
    }

    /// @dev Rounded-up `withdraw` claims can bring the ledger's shares to zero while assets of a fill are still
    ///      claimable. Those assets are a fill, not a refund, so the view asks the payout check the claim asks, and a
    ///      controller that fails it is offered nothing instead of an amount the claim then refuses.
    function testAFillWhoseSharesAreClaimedAwayIsStillHeldToTheRedeemClaim() public {
        _settleRedeem(1, 3);
        vm.prank(controller);
        v.withdraw(1, receiver, controller);
        assertEq(v.claimableRedeemRequest(0, controller), 0, "the ledger's shares are gone");
        assertEq(v.claimableWithdraw(controller), 2, "while assets of the fill remain");

        share.setHook(address(new RoleRefusingHook(Role.Payout, address(0))));
        assertEq(v.maxWithdraw(controller), 0, "the view asks what the claim asks");
        assertEq(v.maxRedeem(controller), 0);

        vm.prank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.withdraw(2, receiver, controller);
    }

    /// @dev A claim takes the refund first and asks its check on its own, so the view does the same: a refused refund
    ///      refuses everything, since execution never reaches the fill, while a refused fill leaves the refund
    ///      claimable, and claiming exactly that much succeeds.
    function testAFillAndARefundAreCheckedApart() public {
        _settleRedeem(1_000e18, 1_000e6);
        uint96 localId = _requestDeposit(500e6);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 500e6, 500e6);
        assertEq(v.maxWithdraw(controller), 1_500e6, "fill and refund");

        share.setHook(address(new RoleRefusingHook(Role.Refund, controller)));
        assertEq(v.maxWithdraw(controller), 0, "a refused refund leaves nothing: it is taken first");
        assertEq(v.maxRedeem(controller), 1_000e18, "`redeem` never takes the refund, so refusing it changes nothing");
        share.setHook(address(new RoleRefusingHook(Role.Payout, address(0))));
        assertEq(v.maxWithdraw(controller), 500e6, "a refused fill leaves the refund");
        vm.startPrank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.withdraw(500e6 + 1, controller, controller);
        v.withdraw(500e6, controller, controller);
        vm.stopPrank();

        share.setHook(address(0));
        assertEq(v.maxWithdraw(controller), 1_000e6, "the fill remains");
    }

    /// @dev The deposit-side twin: refunded shares carry no assets, and filled shares are held to the deposit claim
    ///      even when the assets they were bought with have been claimed away.
    function testAFilledMintIsHeldToTheDepositClaimWhateverTheAssetsLeft() public {
        _settleDeposit(1, 3);
        vm.prank(controller);
        v.mint(1, receiver, controller);
        assertEq(v.claimableDepositRequest(0, controller), 0, "the assets are claimed away");
        assertEq(v.claimableMint(controller), 2, "while filled shares remain");

        // A cancelled redemption leaves refunded shares beside the fill
        uint96 localId = _requestRedeem(400e18);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(localId, 400e18, 400e18);

        share.setHook(address(new RoleRefusingHook(Role.Refund, controller)));
        assertEq(v.maxMint(controller), 0, "a refused refund leaves nothing: it is taken first");

        share.setHook(address(new RoleRefusingHook(Role.Entry, controller)));
        assertEq(v.maxMint(controller), 400e18, "the fill is refused, the refund is not");
        vm.startPrank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.mint(400e18 + 1, controller, controller);
        v.mint(400e18, controller, controller);
        vm.stopPrank();

        share.setHook(address(0));
        assertEq(v.maxMint(controller), 2, "the fill remains");
    }

    /// @dev The assets of a cancelled deposit, taken back by the controller itself, are the refund alone: the
    ///      redeem claim, which asks the payout role, is not asked.
    function testACancelledDepositIsRefundedToTheControllerUnderTheRefundAction() public {
        uint96 localId = _requestDeposit(1_000e6);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 1_000e6, 1_000e6);

        share.setHook(address(new RoleRefusingHook(Role.Payout, address(0))));
        assertEq(v.maxWithdraw(controller), 1_000e6, "the view agrees");

        vm.prank(controller);
        v.withdraw(1_000e6, controller, controller);
    }

    /// @dev To another receiver the refund is an ordinary claim, held to the receiver's bar.
    function testACancelledDepositRefundToAnotherReceiverIsARedeemClaim() public {
        uint96 localId = _requestDeposit(1_000e6);
        vm.prank(router);
        IVaultDepositCallbacks(address(vault)).cancelDeposit(localId, 1_000e6, 1_000e6);

        share.setHook(address(new RoleRefusingHook(Role.Payout, address(0))));
        vm.prank(controller);
        vm.expectRevert(RoleRefusingHook.Refused.selector);
        v.withdraw(1_000e6, receiver, controller);
    }

    /// @dev The instant branch of the capacity views asks the hook the same question the execute
    ///      will: whether the token mints to the receiver, and whether the owner may exit.
    function testInstantCapacityIsHiddenWhereTheHookWouldRefuse() public {
        assertEq(v.maxDeposit(controller), 1_000_000e6, "an open lane");
        assertEq(v.maxRedeem(controller), 1_000_000e18);

        share.setBlocked(controller, true);
        assertEq(v.maxDeposit(controller), 0, "no deposit capacity into a refused receiver");
        assertEq(v.maxMint(controller), 0);

        share.setHook(address(new RoleRefusingHook(Role.Exit, controller)));
        assertEq(v.maxRedeem(controller), 0, "no redeem capacity for a refused exit");
        assertEq(v.maxWithdraw(controller), 0);
    }

    /// @dev A cancelled redeem credits shares at no asset value. The 2-arg `deposit` routes on those
    ///      shares and takes the claim path, so `maxDeposit` must not quote the instant lane there.
    function testACancelledRedeemCreditDoesNotAdvertiseInstantDeposits() public {
        uint96 localId = _requestRedeem(1_000e18);
        vm.prank(router);
        IVaultRedeemCallbacks(address(vault)).cancelRedeem(localId, 1_000e18, 1_000e18);

        assertEq(v.maxMint(controller), 1_000e18, "the credit is claimable by mint");
        assertEq(v.maxDeposit(controller), 0, "and not instant deposit capacity");
    }

    /// @dev Every instant execute is behind `linked`, so an unlinked vault reports no instant capacity
    ///      rather than capacity that reverts, while what is claimable stays reported.
    function testAnUnlinkedVaultReportsClaimsButNoInstantCapacity() public {
        _settleDeposit(1_000e6, 1_000e18);
        assertEq(v.maxMint(controller), 1_000e18);
        assertEq(v.maxRedeem(outsider), 1_000_000e18);

        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), false))
        );
        assertEq(v.maxDeposit(controller), 1_000e6, "async claim");
        assertEq(v.maxMint(controller), 1_000e18);
        assertEq(v.maxDeposit(outsider), 0, "instant lane");
        assertEq(v.maxMint(outsider), 0);
        assertEq(v.maxWithdraw(outsider), 0);
        assertEq(v.maxRedeem(outsider), 0);
        assertEq(v.withdrawCapacity(outsider), 0);
    }

    //----------------------------------------------------------------------------------------------
    // Caller, link and rounding pins
    //----------------------------------------------------------------------------------------------

    function testTransferRequestsRequireTheControllerOrItsOperator() public {
        uint96 depositId = _requestDeposit(1_000e6);
        uint96 redeemId = _requestRedeem(1_000e18);

        vm.startPrank(outsider);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        v.transferDepositRequest(_requestId(depositId), controller, outsider);
        vm.expectRevert(IVaultErrors.InvalidController.selector);
        v.transferRedeemRequest(_requestId(redeemId), controller, outsider);
        vm.stopPrank();
    }

    function testRequestDepositRefusesAnUnlinkedVault() public {
        _unlink();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestDeposit(1e6, controller, controller);
    }

    function testRequestRedeemRefusesAnUnlinkedVault() public {
        _unlink();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestRedeem(1e18, controller, controller);
    }

    function testTransferDepositRequestRefusesAnUnlinkedVault() public {
        uint96 localId = _requestDeposit(1_000e6);
        _unlink();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.transferDepositRequest(_requestId(localId), controller, receiver);
    }

    function testTransferRedeemRequestRefusesAnUnlinkedVault() public {
        uint96 localId = _requestRedeem(1_000e18);
        _unlink();

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.transferRedeemRequest(_requestId(localId), controller, receiver);
    }

    /// @dev Only an operator of the owner moves the shares as the owner; anyone else spends their own allowance.
    function testRequestRedeemByANonOperatorSpendsItsOwnAllowance() public {
        address spender = makeAddr("spender");

        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.transferSharesFrom.selector, POOL, SC, spender, controller, escrow, uint256(1e18)
            )
        );
        // The spender is the request's controller: on a vault with both lanes a spender may not credit the owner
        vm.prank(spender);
        v.requestRedeem(1e18, spender, controller);
    }

    function testRequestRedeemByAnOperatorMovesTheSharesAsTheOwner() public {
        vm.prank(controller);
        v.setOperator(outsider, true);

        vm.expectCall(
            spoke,
            abi.encodeWithSelector(
                ISpoke.transferSharesFrom.selector, POOL, SC, controller, controller, escrow, uint256(1e18)
            )
        );
        vm.prank(outsider);
        v.requestRedeem(1e18, controller, controller);
    }

    /// @dev 3 assets settle to 10 shares, so a claim of 1 asset is worth 3.33 shares and is floored.
    function testDepositClaimRoundsSharesDown() public {
        _settleDeposit(3, 10);

        vm.prank(controller);
        assertEq(v.deposit(1, receiver, controller), 3, "shares round down");
        assertEq(v.claimableMint(controller), 7);
        assertEq(v.claimableDepositRequest(0, controller), 2);
    }

    function testFullDepositClaimEmptiesTheLedger() public {
        _settleDeposit(3, 10);

        vm.prank(controller);
        assertEq(v.deposit(3, receiver, controller), 10);
        assertEq(v.claimableDepositRequest(0, controller), 0, "no assets left");
        assertEq(v.claimableMint(controller), 0, "no shares left");
    }

    /// @dev 1 of 10 shares costs 0.3 assets and is ceiled.
    function testMintClaimRoundsAssetsUp() public {
        _settleDeposit(3, 10);

        vm.prank(controller);
        assertEq(v.mint(1, receiver, controller), 1, "assets round up");
    }

    function testMintClaimSpendsMaxMint() public {
        _settleDeposit(3, 10);

        vm.prank(controller);
        v.mint(4, receiver, controller);
        assertEq(v.claimableMint(controller), 6, "maxMint decrements");
    }

    /// @dev 10 shares settle to 3 assets, so 1 asset burns 3.33 shares and is ceiled.
    function testWithdrawClaimBurnsSharesRoundedUp() public {
        _settleRedeem(10, 3);

        vm.prank(controller);
        assertEq(v.withdraw(1, receiver, controller), 4, "shares round up");
    }

    /// @dev The vault is linked only to the registry's entry for its own pool, share class and asset; an entry
    ///      that differs in any one of the three, even a live one, does not link it.
    function testAnEntryForAnotherShareClassDoesNotLinkTheVault() public {
        _linkedTo(POOL, ShareClassId.wrap(bytes16("other")), ASSET_ID);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestDeposit(1e6, controller, controller);
    }

    function testAnEntryForAnotherPoolDoesNotLinkTheVault() public {
        _linkedTo(PoolId.wrap(2), SC, ASSET_ID);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestDeposit(1e6, controller, controller);
    }

    function testAnEntryForAnotherAssetDoesNotLinkTheVault() public {
        _linkedTo(POOL, SC, newAssetId(0, 2));

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.VaultNotLinked.selector);
        v.requestDeposit(1e6, controller, controller);
    }

    /// @dev A request id carries the vault it was issued by. A local id that exists here, under another vault's
    ///      address, names no request of this vault.
    function testARequestIdOfAnotherVaultCannotBeTransferred() public {
        uint96 depositId = _requestDeposit(1_000e6);
        uint96 redeemId = _requestRedeem(1_000e18);
        address other = makeAddr("otherVault");

        vm.startPrank(controller);
        vm.expectRevert(IVaultErrors.InvalidRequestId.selector);
        v.transferDepositRequest(VaultRequestIdLib.from(other, depositId).raw(), controller, receiver);
        vm.expectRevert(IVaultErrors.InvalidRequestId.selector);
        v.transferRedeemRequest(VaultRequestIdLib.from(other, redeemId).raw(), controller, receiver);
        vm.stopPrank();
    }

    /// @dev `withdraw` pays exactly what was asked and burns the shares that cover it rounded up, so the pool never
    ///      pays out more value than the shares it takes. At a share price of 3, one USDC is a third of a share.
    function testInstantWithdrawBurnsSharesRoundedUp() public {
        _instantCaps(1_000_000e6, 1_000_000e6);
        _prices(ONE, D18.wrap(3e18));
        share.setBalance(controller, 1e18);

        vm.prank(controller);
        assertEq(v.withdraw(1e6, receiver), 333333333333333334, "a third of a share rounds up");
    }

    //----------------------------------------------------------------------------------------------
    // Properties pinned after the mutation sweep
    //----------------------------------------------------------------------------------------------

    /// @dev A rebate is converted on top of the deposit, so `maxDeposit` leaves the share supply room for it: a deposit
    ///      of the reported maximum issues within `uint128` rather than overflowing.
    function testMaxDepositLeavesSupplyRoomForARebate() public {
        _instantCaps(type(uint128).max, type(uint128).max);
        _instantFees(-10e6, 0);
        uint256 assets = v.maxDeposit(controller);
        assertGt(assets, 0, "the lane is open");

        asset.mint(controller, assets);
        asset.mint(feeRecipient, 10e6);
        vm.prank(feeRecipient);
        asset.approve(address(vault), type(uint256).max);
        vm.startPrank(controller);
        asset.approve(address(vault), assets);
        uint256 shares = v.deposit(assets, controller);
        vm.stopPrank();
        assertEq(shares, (assets + 10e6) * 1e12, "the rebate is issued on top, within the supply");
    }

    /// @dev The hook is asked about the assets the caller pays, not the part of them that reaches the escrow after
    ///      the fee.
    function testTheHookSeesTheInstantDepositTheCallerPays() public {
        _instantFees(10e6, 0);
        asset.mint(controller, 1_000e6);
        vm.prank(controller);
        asset.approve(address(vault), 1_000e6);

        VaultAction memory action =
            VaultAction(VaultActionKind.InstantDeposit, controller, controller, controller, 1_000e6, 990e18);
        vm.expectCall(
            actionHook,
            abi.encodeWithSelector(IRoleHook.onRoles.selector, address(share), VaultActionLib.roleChecks(action))
        );
        vm.prank(controller);
        v.deposit(1_000e6, controller);
    }

    /// @dev The hook is asked about the whole payout, the rebate the fee source adds included, since that is what
    ///      reaches the receiver.
    function testTheHookSeesTheInstantPayoutWithItsRebate() public {
        _instantFees(0, -10e6);
        share.setBalance(controller, 100e18);
        asset.mint(feeRecipient, 10e6);
        vm.prank(feeRecipient);
        asset.approve(address(vault), type(uint256).max);

        VaultAction memory action =
            VaultAction(VaultActionKind.InstantRedeem, controller, controller, receiver, 110e6, 100e18);
        vm.expectCall(
            actionHook,
            abi.encodeWithSelector(IRoleHook.onRoles.selector, address(share), VaultActionLib.roleChecks(action))
        );
        vm.prank(controller);
        v.redeem(100e18, receiver);
    }

    /// @dev A hook payout cap between the payout without the rebate and with it: the full balance would pay past the
    ///      cap, so `maxRedeem` reports only what pays within it.
    function testMaxRedeemCountsTheRebateAgainstAPayoutCap() public {
        _instantFees(0, -10e6);
        vm.mockCall(
            actionHook,
            abi.encodeWithSelector(IRoleHook.maxAllowed.selector),
            abi.encode(uint256(1_005e6), type(uint256).max)
        );
        share.setBalance(controller, 1_000e18);

        uint256 shares = v.maxRedeem(controller);
        assertLt(shares, 1_000e18, "the whole balance would pay 1,010 against a cap of 1,005");
        assertLe(shares / 1e12 + 10e6, 1_005e6, "what it reports pays within the cap");
    }

    /// @dev A position whose whole value goes to the exit fee pays nothing, so it is not offered: redeeming it would
    ///      revert.
    function testMaxRedeemIsZeroWhenTheFeeTakesTheWholeValue() public {
        _instantFees(0, 1);
        share.setBalance(controller, 1e12);
        assertEq(v.maxRedeem(controller), 0, "one unit of value, one unit of fee");
    }

    /// @dev A deposit claim that converts to no shares is refused, rather than taking the claimable assets for
    ///      nothing.
    function testADepositClaimOfNoSharesIsRefused() public {
        _settleDeposit(1_000e6, 1);
        uint256 before = v.claimableMint(controller);

        vm.prank(controller);
        vm.expectRevert(IVaultErrors.ZeroAmount.selector);
        v.deposit(1, receiver, controller);
        assertEq(v.claimableMint(controller), before, "and the ledger is untouched");
    }

    /// @dev A transfer of a partly settled batch position folds the sender's settled slice into the sender's own
    ///      ledger and moves only the remainder.
    function testATransferOfAPartlySettledBatchMovesOnlyTheRemainder() public {
        IAsyncVault grouped = IAsyncVault(address(_perPeriodVault()));
        address other = makeAddr("other");
        address recipient = makeAddr("recipient");
        asset.mint(other, 3_000e6);
        vm.prank(other);
        asset.approve(address(grouped), 3_000e6);

        vm.prank(controller);
        uint256 requestId = grouped.requestDeposit(1_000e6, controller, controller);
        vm.prank(other);
        grouped.requestDeposit(3_000e6, other, other);
        uint96 localId = uint96(requestId);
        vm.warp(block.timestamp + 1 days);
        grouped.flushRequest(localId);

        vm.startPrank(router);
        IVaultDepositCallbacks(address(grouped)).approveDeposits(localId, 2_000e6);
        IVaultDepositCallbacks(address(grouped)).issueShares(localId, 2_000e18);
        IVaultDepositCallbacks(address(grouped)).fulfillDepositRequest(localId, 2_000e6, 2_000e18);
        vm.stopPrank();

        vm.prank(controller);
        grouped.transferDepositRequest(requestId, controller, recipient);
        assertEq(grouped.claimableMint(controller), 500e18, "the settled half stays with the sender");
        assertEq(grouped.pendingDepositRequest(0, controller), 0, "who has nothing pending left");
        assertEq(grouped.pendingDepositRequest(0, recipient), 500e6, "and only the unsettled half moved");
    }

    /// @dev On a vault without an instant lane anyone may request for any controller, but a position the controller
    ///      did not submit takes a free slot only: it never evicts one of the controller's own positions.
    function testARequestForAnotherControllerNeverEvictsTheirOwn() public {
        Vault asyncOnly = _vaultWith(address(requestPolicy), address(0));
        address stranger = makeAddr("stranger");
        asset.mint(stranger, 1e6);
        vm.prank(stranger);
        asset.approve(address(asyncOnly), 1e6);

        vm.prank(controller);
        asyncOnly.requestDeposit(1_000e6, controller, controller);

        vm.expectEmit(address(asyncOnly));
        emit IVaultEvents.OutsideHorizon(VaultRequestIdLib.from(address(asyncOnly), 2).raw(), controller, true);
        vm.prank(stranger);
        asyncOnly.requestDeposit(1e6, controller, stranger);
    }

    /// @dev A position transferred away leaves the sender's horizon, so it cannot later push out one of the sender's
    ///      live positions: with a horizon of two, a live window, a window moved away and a new request fit.
    function testATransferredPositionLeavesTheSendersHorizon() public {
        IAsyncVault grouped = _horizonTwoVault();
        address recipient = makeAddr("recipient");

        vm.prank(controller);
        grouped.requestDeposit(1_000e6, controller, controller);
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(controller);
        uint256 moved = grouped.requestDeposit(1_000e6, controller, controller);
        grouped.transferDepositRequest(moved, controller, recipient);
        vm.stopPrank();

        vm.warp(block.timestamp + 1 days);
        _assertNoEvictionOn(grouped);
    }

    /// @dev A position whose fold completes leaves the horizon at once, so it cannot later push out one of the
    ///      controller's live positions.
    function testACompletedFoldLeavesTheHorizon() public {
        IAsyncVault grouped = _horizonTwoVault();

        vm.prank(controller);
        grouped.requestDeposit(1_000e6, controller, controller);
        vm.warp(block.timestamp + 1 days);
        vm.prank(controller);
        uint96 settled = uint96(grouped.requestDeposit(1_000e6, controller, controller));

        vm.warp(block.timestamp + 1 days);
        grouped.flushRequest(settled);
        vm.startPrank(router);
        IVaultDepositCallbacks(address(grouped)).approveDeposits(settled, 1_000e6);
        IVaultDepositCallbacks(address(grouped)).issueShares(settled, 1_000e18);
        IVaultDepositCallbacks(address(grouped)).fulfillDepositRequest(settled, 1_000e6, 1_000e18);
        vm.stopPrank();
        grouped.foldRequest(settled, controller);
        assertEq(grouped.contribution(settled, controller).amount, 0, "the fold completed");

        _assertNoEvictionOn(grouped);
    }

    /// @dev An own request on a horizon with room evicts nothing: no `OutsideHorizon` for the live first window.
    function _assertNoEvictionOn(IAsyncVault grouped) internal {
        vm.recordLogs();
        vm.prank(controller);
        grouped.requestDeposit(1_000e6, controller, controller);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; i++) {
            assertTrue(
                logs[i].topics[0] != IVaultEvents.OutsideHorizon.selector,
                "a live position was pushed out of the horizon"
            );
        }
    }

    /// @dev Daily windows without a notice, so one is open at a time, and a horizon of two.
    function _horizonTwoVault() internal returns (IAsyncVault) {
        return IAsyncVault(
            address(
                new Vault(
                    POOL,
                    SC,
                    address(asset),
                    ASSET_ID,
                    IShareToken(address(share)),
                    VaultConfig({
                        foldHorizon: 2,
                        spoke: ISpoke(spoke),
                        spokeRegistry: ISpokeRegistry(spokeRegistry),
                        plugins: VaultPlugins({
                            oracle: IVaultOracle(oracle),
                            instantPolicy: IInstantPolicy(address(0)),
                            requestPolicy: IRequestPolicy(address(new PerPeriodPolicy(1 days, 0, 0, 0))),
                            liquidityRoute: ILiquidityRoute(address(0)),
                            settlementObserver: ISettlementObserver(address(0))
                        })
                    })
                )
            )
        );
    }

    /// @dev A vault whose policy does not batch never asks `isClosed`: each request is sent as it is made, even under a
    ///      policy whose `isClosed` reverts, and `flushRequest` then finds nothing queued rather than a closed gate.
    function testANonBatchingVaultNeverAsksIsClosed() public {
        Vault unbatched = _vaultWithPolicy(address(new ClosedRevertsPolicy()));
        vm.expectCall(router, abi.encodeWithSelector(IVaultRequestManager.sendDepositRequest.selector));
        vm.prank(controller);
        uint96 localId = uint96(unbatched.requestDeposit(1_000e6, controller, controller));

        vm.expectRevert(IVaultErrors.NoQueuedRequest.selector);
        unbatched.flushRequest(localId);
    }

    /// @dev Only time advances a vault's windows: anyone may call the policy's hooks directly, and the next request
    ///      still joins the window of its time, while the clock alone opens the next one.
    function testOnlyTimeAdvancesTheWindows() public {
        PerPeriodPolicy policy = new PerPeriodPolicy(1 days, 0, 0, 0);
        Vault grouped = _vaultWithPolicy(address(policy));
        vm.prank(controller);
        uint256 first = grouped.requestDeposit(1_000e6, controller, controller);

        vm.startPrank(outsider);
        for (uint256 i; i < 5; i++) {
            policy.onRequest(address(grouped), outsider, outsider, true, uint128(i + 1));
            policy.isClosed(address(grouped), bytes32(i));
        }
        vm.stopPrank();

        vm.prank(controller);
        assertEq(grouped.requestDeposit(1_000e6, controller, controller), first, "the same window as before");
        vm.warp(block.timestamp + 1 days);
        vm.prank(controller);
        assertNotEq(grouped.requestDeposit(1_000e6, controller, controller), first, "the next window, by the clock");
    }

    function _linkedTo(PoolId poolId, ShareClassId scId, AssetId assetId) internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(poolId, scId, assetId, address(asset), uint256(0), true))
        );
    }

    function _unlink() internal {
        vm.mockCall(
            spokeRegistry,
            abi.encodeWithSelector(ISpokeRegistry.vaultDetails.selector),
            abi.encode(VaultDetails(POOL, SC, ASSET_ID, address(asset), uint256(0), false))
        );
    }
}

/// @dev A share hook that records the shares an account has claimable each time it is asked, and allows everything.
contract ClaimableProbeHook {
    IAsyncVault internal immutable _vault;
    address internal immutable _account;
    uint256[] public seen;

    constructor(IAsyncVault vault_, address account) {
        _vault = vault_;
        _account = account;
    }

    function onRoles(address, RoleCheck[] calldata) external returns (bytes4) {
        seen.push(_vault.claimableMint(_account));
        return ClaimableProbeHook.onRoles.selector;
    }

    function maxAllowed(address, RoleCheck[] calldata) external pure returns (uint256, uint256) {
        return (type(uint256).max, type(uint256).max);
    }

    function checkRoles(address, RoleCheck[] calldata) external pure returns (bool) {
        return true;
    }
}

/// @dev A share hook that refuses one role, to one account or to anyone when it is zero, and allows the rest.
contract RoleRefusingHook {
    Role internal immutable _role;
    address internal immutable _account;

    error Refused();

    constructor(Role role, address account) {
        _role = role;
        _account = account;
    }

    function onRoles(address token, RoleCheck[] calldata checks) external view returns (bytes4) {
        require(checkRoles(token, checks), Refused());
        return RoleRefusingHook.onRoles.selector;
    }

    function maxAllowed(address, RoleCheck[] calldata) external pure returns (uint256, uint256) {
        return (type(uint256).max, type(uint256).max);
    }

    function checkRoles(address, RoleCheck[] calldata checks) public view returns (bool) {
        for (uint256 i; i < checks.length; i++) {
            if (checks[i].role == _role && (_account == address(0) || checks[i].to == _account)) return false;
        }
        return true;
    }
}

/// @dev A non-batching policy whose `isClosed` reverts, so any read of it fails the call that made it.
contract ClosedRevertsPolicy is IRequestPolicy {
    bool public constant isBatched = false;
    bool public constant supportsTransfers = false;
    uint256 public constant maxOpenBuckets = 1;

    function onRequest(address, address, address, bool, uint128) external pure returns (bytes32) {
        return 0;
    }

    function isClosed(address, bytes32) external pure returns (bool) {
        revert("isClosed was asked");
    }
}

/// @dev Unbatched, it keys each request by its controller and lets requests change hands: a custom policy the shipped
///      ones do not cover. Batched, it answers the zero key, which names no batch.
contract ControllerKeyPolicy is IRequestPolicy {
    bool public immutable isBatched;

    constructor(bool isBatched_) {
        isBatched = isBatched_;
    }

    function onRequest(address, address controller, address, bool, uint128) external view returns (bytes32) {
        return isBatched ? bytes32(0) : CastLib.toBytes32(controller);
    }

    function isClosed(address, bytes32) external pure returns (bool) {
        return true;
    }

    function supportsTransfers() external pure returns (bool) {
        return true;
    }

    function maxOpenBuckets() external pure returns (uint256) {
        return 1;
    }
}

/// @dev A non-batching policy that answers every request with one key, standing in for a policy that is buggy or hostile
///      about the buckets it names.
contract FixedKeyPolicy is IRequestPolicy {
    bytes32 internal immutable _key;

    constructor(bytes32 key_) {
        _key = key_;
    }

    function onRequest(address, address, address, bool, uint128) external view returns (bytes32) {
        return _key;
    }

    function isClosed(address, bytes32) external pure returns (bool) {
        return true;
    }

    function supportsTransfers() external pure returns (bool) {
        return true;
    }

    function maxOpenBuckets() external pure returns (uint256) {
        return 1;
    }

    function isBatched() external pure returns (bool) {
        return false;
    }
}
