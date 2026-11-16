// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {EndToEndFlows} from "./EndToEnd.t.sol";
import {IntegrationConstants} from "./utils/IntegrationConstants.sol";

import {CastLib} from "../../src/misc/libraries/CastLib.sol";

import {PoolId} from "../../src/core/types/PoolId.sol";
import {AssetId} from "../../src/core/types/AssetId.sol";
import {RequestId} from "../../src/core/types/RequestId.sol";
import {ShareClassId} from "../../src/core/types/ShareClassId.sol";
import {IEscrow} from "../../src/core/spoke/interfaces/IEscrow.sol";
import {IGateway} from "../../src/core/messaging/interfaces/IGateway.sol";
import {IHubRequestManager} from "../../src/core/hub/interfaces/IHubRequestManager.sol";
import {IMessageHandler} from "../../src/core/messaging/interfaces/IMessageHandler.sol";
import {IHubRequestManagerCallback} from "../../src/core/hub/interfaces/IHubRequestManagerCallback.sol";

import {RequestMessageLib, RequestType} from "../../src/vaults/messaging/libraries/RequestMessageLib.sol";
import {RequestCallbackMessageLib} from "../../src/vaults/messaging/libraries/RequestCallbackMessageLib.sol";

import {IShareTokenHook} from "../../src/token/hooks/interfaces/IShareTokenHook.sol";
import {UpdateRestrictionMessageLib} from "../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {IAsyncVault, IVaultErrors} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {IOrderBook, OrderBookAction, Cancellation} from "../../src/vaults/hub/interfaces/IOrderBook.sol";

import {Vm} from "forge-std/Vm.sol";

import {IShareToken} from "../../src/token/interfaces/IShareToken.sol";
import {ITransferHook} from "../../src/token/interfaces/ITransferHook.sol";

/// @dev Stands in for the hub -> spoke transport while a message is in flight.
contract InFlight is IMessageHandler {
    uint16 public from;
    bytes public held;

    function handle(uint16 centrifugeId, bytes calldata message) external {
        from = centrifugeId;
        held = message;
    }

    function deliver(IMessageHandler to) external {
        to.handle(from, held);
    }
}

/// @dev A pool-registered hub request manager outside the shipped OrderBook. Deposits settle on arrival at
///      a fixed share amount (an instant-settlement manager: same-chain, the callback runs inside the
///      investor's `requestDeposit`). Anything else it is told to send, it sends unchecked.
contract SettlingHubManager is IHubRequestManager {
    using RequestMessageLib for bytes;
    using RequestCallbackMessageLib for *;

    IHubRequestManagerCallback public immutable hub;
    uint128 public sharesPerDeposit;
    RequestId public lastRedeem;

    constructor(IHubRequestManagerCallback hub_) {
        hub = hub_;
    }

    receive() external payable {}

    function setShares(uint128 shares) external {
        sharesPerDeposit = shares;
    }

    function request(PoolId poolId, ShareClassId scId, AssetId assetId, bytes calldata payload) external {
        if (payload.requestType() == RequestType.RedeemRequest) {
            lastRedeem = payload.deserializeRedeemRequest().requestId;
            return;
        }
        if (sharesPerDeposit == 0) return;

        RequestMessageLib.DepositRequest memory m = payload.deserializeDepositRequest();
        bytes memory callback =
            RequestCallbackMessageLib.SettledDeposit(m.requestId, m.amount, sharesPerDeposit).serialize();
        hub.requestCallback(poolId, scId, assetId, callback, 0, false, address(this));
    }

    function cancelRedeem(PoolId poolId, ShareClassId scId, AssetId assetId, uint128 gross, uint128 net) external {
        bytes memory callback = RequestCallbackMessageLib.CancelledRedeem(lastRedeem, gross, net).serialize();
        hub.requestCallback{value: address(this).balance}(poolId, scId, assetId, callback, 0, false, address(this));
    }

    function supportsInterface(bytes4) external pure returns (bool) {
        return true;
    }
}

/// @dev The security review's findings, replayed as their PoCs on the deployer-wired stack (real spoke,
///      escrow, share token, hooks, OrderBook and messaging) and asserting the fixed behaviour. The
///      mock-based regressions next to each fix pin the mechanism; these pin the outcome end to end.
contract SecurityRegressionsBase is EndToEndFlows {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    address immutable BOB = makeAddr("BOB");
    address immutable CLEAN = makeAddr("CLEAN");
    address immutable OPERATOR = makeAddr("OPERATOR");

    function _member(address who) internal {
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionMemberMsg(who), EXTRA_GAS, REFUND
        );
    }

    function _memberUntil(address who, uint64 validUntil) internal {
        bytes memory payload = UpdateRestrictionMessageLib.UpdateRestrictionMember({
            user: who.toBytes32(), validUntil: validUntil
        }).serialize();
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(POOL_A, SC_1, s.centrifugeId, payload, EXTRA_GAS, REFUND);
    }

    function _freeze(address who) internal {
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionFreezeMsg(who), EXTRA_GAS, REFUND
        );
    }

    function _unfreeze(address who) internal {
        vm.prank(FM);
        h.hub.updateRestriction{value: GAS}(
            POOL_A, SC_1, s.centrifugeId, _updateRestrictionUnfreezeMsg(who), EXTRA_GAS, REFUND
        );
    }

    function _useHook(address hook) internal {
        vm.startPrank(FM);
        _setHook(s, hook);
        vm.stopPrank();
    }

    function _setUpPool(bool sameChain) internal {
        _configurePool(sameChain);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());
    }

    function _instantVault() internal returns (IAsyncVault vault) {
        vault = _deployInstantVault();
        lastInstantVault = address(vault);
        _configureInstantLane(USDC_AMOUNT_1 * 10, 0, 0, address(0));
    }

    function _instantDeposit(IAsyncVault vault, address who, uint128 assets) internal returns (uint256 shares) {
        if (s.usdc.balanceOf(who) < assets) s.usdc.mint(who, assets);
        vm.startPrank(who);
        s.usdc.approve(address(vault), assets);
        shares = vault.deposit(assets, who);
        vm.stopPrank();
    }

    /// @dev The selector of the most recent `FailMessage` among the recorded logs, or zero.
    function _lastFailure() internal returns (bytes4 selector) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = logs.length; i > 0; i--) {
            if (logs[i - 1].topics[0] == IGateway.FailMessage.selector) {
                (, bytes memory err) = abi.decode(logs[i - 1].data, (bytes32, bytes));
                return bytes4(err);
            }
        }
    }

    function _netQueued() internal view returns (int256) {
        (uint128 deposits, uint128 withdrawals) = s.spoke.snapshotQueue().queuedAssets(POOL_A, SC_1, s.usdcId);
        return int256(uint256(deposits)) - int256(uint256(withdrawals));
    }
}

/// @dev Async lifecycle review: A-1, A-2, and the cancellation rebate (wischli blocker 1).
/// forge-config: default.isolate = true
contract AsyncLifecycleRegressionTest is SecurityRegressionsBase {
    using CastLib for *;

    /// @dev A-1 (sec-async `InFlightRedeemRace`). A redeem fill in flight to the spoke counts on idle cash
    ///      that an instant exit takes during the latency. The fill used to land anyway: Alice's shares
    ///      burnt, a payout reserved against an empty escrow, and the hub told the holding went negative.
    ///      Now the fill waits, retryable, until the escrow can back it, and nothing is lost meanwhile.
    function testAnInFlightRedeemFillWaitsForTheCashTheInstantLaneTook() public {
        _setUpPool(false);
        IAsyncVault vault = _instantVault();
        IShareToken share = IShareToken(vault.share());
        IEscrow escrow = IEscrow(vault.escrow());
        _member(INVESTOR_A);
        _member(BOB);

        uint256 aliceShares = _instantDeposit(vault, INVESTOR_A, USDC_AMOUNT_1);
        uint256 bobShares = _instantDeposit(vault, BOB, USDC_AMOUNT_1);

        // The pool keeps half idle and deploys the rest.
        vm.prank(BSM);
        s.spoke.withdraw(POOL_A, SC_1, address(s.usdc), 0, BSM, USDC_AMOUNT_1);
        assertEq(escrow.availableBalanceOf(SC_1, address(s.usdc), 0), USDC_AMOUNT_1, "one deposit's worth idle");

        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(aliceShares, INVESTOR_A, INVESTOR_A));

        InFlight transport = new InFlight();
        poolAdapterHToS.setEndpoint(transport);
        _fulfill(false, requestId, uint128(aliceShares));
        poolAdapterHToS.setEndpoint(poolAdapterSToH);
        assertEq(vault.maxWithdraw(INVESTOR_A), 0, "fill still in flight");

        // During the latency, Bob exits through the instant lane against the same idle cash.
        vm.prank(BOB);
        vault.redeem(bobShares, BOB);
        assertEq(escrow.availableBalanceOf(SC_1, address(s.usdc), 0), 0, "idle cash gone");
        int256 netBefore = _netQueued();

        // The fill lands and is refused: the escrow cannot back the payout.
        vm.recordLogs();
        transport.deliver(IMessageHandler(address(poolAdapterSToH)));
        assertEq(_lastFailure(), IVaultErrors.InsufficientLiquidity.selector, "the settlement waits for liquidity");

        assertEq(share.balanceOf(address(escrow)), aliceShares, "alice's shares are still parked, not burnt");
        assertEq(vault.pendingRedeemRequest(0, INVESTOR_A), aliceShares, "her request is still pending");
        assertEq(vault.maxWithdraw(INVESTOR_A), 0, "no claim is promised against an empty escrow");
        assertEq(_netQueued(), netBefore, "and the hub is told of no outflow the escrow cannot make");

        // Once the pool refunds the escrow, the same message settles and Alice is paid in full.
        vm.startPrank(BSM);
        s.usdc.approve(address(s.spoke), USDC_AMOUNT_1);
        s.spoke.deposit(POOL_A, SC_1, address(s.usdc), 0, USDC_AMOUNT_1);
        vm.stopPrank();

        bytes memory batch = transport.held();
        bytes memory message = new bytes(batch.length - 2);
        for (uint256 i; i < message.length; i++) {
            message[i] = batch[i + 2];
        }
        s.gateway.retry(h.centrifugeId, message);

        uint128 payout = shareToAsset(uint128(aliceShares));
        assertEq(share.balanceOf(address(escrow)), 0, "the shares are revoked on settlement");
        assertEq(vault.maxWithdraw(INVESTOR_A), payout, "the claim opens");

        uint256 before = s.usdc.balanceOf(INVESTOR_A);
        vm.prank(INVESTOR_A);
        vault.withdraw(payout, INVESTOR_A, INVESTOR_A);
        assertEq(s.usdc.balanceOf(INVESTOR_A) - before, payout, "and it is paid");
    }

    /// @dev A-2 (sec-async `SyncHubManagerDeposit`). With a hub request manager that settles inside the
    ///      flush, the settlement used to run before the deposit was escrowed and reserved, so the assets
    ///      stayed stranded under the request's reservation and the hub was told nothing arrived while the
    ///      shares were issued. Now the approval releases them into the holding.
    function testADepositSettledInsideTheFlushReachesTheHolding() public {
        _setUpPool(true);
        IAsyncVault vault = _deployVault();
        IEscrow escrow = IEscrow(vault.escrow());

        SettlingHubManager mgr = new SettlingHubManager(IHubRequestManagerCallback(address(h.hub)));
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        mgr.setShares(shares);
        vm.prank(address(h.hub));
        h.hubRegistry.setHubRequestManager(POOL_A, s.centrifugeId, IHubRequestManager(address(mgr)));

        int256 netBefore = _netQueued();

        vm.startPrank(INVESTOR_A);
        s.usdc.approve(address(vault), USDC_AMOUNT_1);
        uint256 requestId = vault.requestDeposit(USDC_AMOUNT_1, INVESTOR_A, INVESTOR_A);
        vm.stopPrank();

        assertEq(vault.maxMint(INVESTOR_A), shares, "settled in-line");
        bytes32 reason = keccak256(abi.encode(bytes32(uint256(1)), uint96(requestId)));
        assertEq(escrow.reservedBy(SC_1, address(vault), reason, address(s.usdc), 0), 0, "nothing stranded");
        assertEq(escrow.availableBalanceOf(SC_1, address(s.usdc), 0), USDC_AMOUNT_1, "the deposit is pool cash");
        assertEq(_netQueued() - netBefore, int256(uint256(USDC_AMOUNT_1)), "and the hub is told it arrived");

        vm.prank(INVESTOR_A);
        vault.mint(shares, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), shares);
    }

    /// @dev wischli blocker 1, hub layer. A redeem cancellation with `net > amount` would credit shares
    ///      that nothing backs, out of other investors' escrowed shares. The OrderBook refuses it whatever
    ///      the pool's policy allows, so the manager cannot send it.
    function testTheOrderBookRefusesACancellationPayingMoreThanItCancels(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        _member(INVESTOR_A);

        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(shares / 10, INVESTOR_A, INVESTOR_A));

        bytes memory payload = abi.encode(
            OrderBookAction.Cancel,
            Cancellation(false, SC_1, s.usdcId, requestId, shares / 10, shares, EXTRA_GAS, REFUND)
        );
        vm.deal(FM, GAS);
        vm.prank(FM);
        vm.expectRevert(IOrderBook.NetExceedsGross.selector);
        h.hub.managerCall{value: GAS}(
            POOL_A, h.centrifugeId, address(h.orderBook).toBytes32(), payload, EXTRA_GAS, GAS, REFUND
        );

        assertEq(h.orderBook.redeemOrders(POOL_A, SC_1, s.usdcId, requestId), shares / 10, "order untouched");
        assertEq(vault.maxMint(INVESTOR_A), 0, "no shares credited");
    }

    /// @dev wischli blocker 1, vault layer. A hub request manager other than the OrderBook is not trusted
    ///      to keep the bound either: the vault refuses the callback, so the investor's claim stays what
    ///      the escrow backs and the other holder's parked shares stay theirs.
    function testTheVaultRefusesACancellationPayingMoreThanItCancels() public {
        IAsyncVault vault = _testAsyncDeposit(false);
        IShareToken share = IShareToken(vault.share());
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        _member(INVESTOR_A);

        SettlingHubManager mgr = new SettlingHubManager(IHubRequestManagerCallback(address(h.hub)));
        vm.prank(address(h.hub));
        h.hubRegistry.setHubRequestManager(POOL_A, s.centrifugeId, IHubRequestManager(address(mgr)));

        vm.prank(INVESTOR_A);
        vault.requestRedeem(shares / 10, INVESTOR_A, INVESTOR_A);
        uint256 parked = share.balanceOf(vault.escrow());

        vm.deal(address(mgr), GAS);
        vm.recordLogs();
        mgr.cancelRedeem(POOL_A, SC_1, s.usdcId, shares / 10, shares);
        assertEq(_lastFailure(), IVaultErrors.NetExceedsGross.selector, "the vault refuses the callback");

        assertEq(vault.maxMint(INVESTOR_A), 0, "no shares credited");
        assertEq(vault.pendingRedeemRequest(0, INVESTOR_A), shares / 10, "the request is still pending");
        assertEq(share.balanceOf(vault.escrow()), parked, "the escrow's shares are untouched");
    }
}

/// @dev Share-custody review: C-1, C-3, and the instant exit's redeem-request gate (custody K-1,
///      wischli blocker 2).
/// forge-config: default.isolate = true
contract ShareCustodyRegressionTest is SecurityRegressionsBase {
    function _fulfilledDeposit(bool sameChain, bool freezeOnly) internal returns (IAsyncVault vault, uint128 shares) {
        _setUpPool(sameChain);
        if (freezeOnly) _useHook(address(s.freezeOnlyHook));
        vault = _deployVault();
        _member(INVESTOR_A);

        RequestId requestId = _requestDeposit(vault, USDC_AMOUNT_1);
        _fulfill(true, requestId, USDC_AMOUNT_1);
        shares = assetToShare(USDC_AMOUNT_1);
    }

    /// @dev C-1 (sec-custody F1a, boundary PoC 1): a frozen controller took delivery of its fulfilled
    ///      deposit by naming a clean receiver, since the escrow -> receiver leg never sees the
    ///      controller. Refused under both hooks, on both claim entrypoints; unfreezing reopens it.
    function _assertFrozenControllerCannotClaimElsewhere(bool sameChain, bool freezeOnly) internal {
        (IAsyncVault vault, uint128 shares) = _fulfilledDeposit(sameChain, freezeOnly);
        IShareToken share = IShareToken(vault.share());

        _freeze(INVESTOR_A);
        assertEq(vault.maxMint(INVESTOR_A), 0, "the view hides the claim");

        vm.startPrank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.deposit(USDC_AMOUNT_1, CLEAN, INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.mint(shares, CLEAN, INVESTOR_A);
        vm.stopPrank();
        assertEq(share.balanceOf(CLEAN), 0, "nothing reached the clean address");

        _unfreeze(INVESTOR_A);
        vm.prank(INVESTOR_A);
        vault.mint(shares, CLEAN, INVESTOR_A);
        assertEq(share.balanceOf(CLEAN), shares, "an unfrozen controller may name any receiver");
    }

    function testAFrozenControllerCannotClaimToAnotherReceiverUnderRedemptionRestrictions(bool sameChain) public {
        _assertFrozenControllerCannotClaimElsewhere(sameChain, false);
    }

    function testAFrozenControllerCannotClaimToAnotherReceiverUnderFreezeOnly(bool sameChain) public {
        _assertFrozenControllerCannotClaimElsewhere(sameChain, true);
    }

    /// @dev C-1 through an operator (sec-custody PoC2): under FreezeOnly, a clean operator of a frozen
    ///      controller claimed the controller's shares to itself.
    function testAnOperatorCannotClaimAFrozenControllersShares() public {
        (IAsyncVault vault, uint128 shares) = _fulfilledDeposit(true, true);

        vm.prank(INVESTOR_A);
        vault.setOperator(OPERATOR, true);
        _freeze(INVESTOR_A);

        vm.prank(OPERATOR);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.mint(shares, OPERATOR, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(OPERATOR), 0);
    }

    /// @dev C-1 on cancelled redeem shares (sec-custody F1b): a frozen holder parked its shares in a
    ///      redeem request, had it cancelled, and minted them out to a clean address, though a direct
    ///      transfer of the same shares is blocked.
    function testAFrozenHolderCannotMoveCancelledRedeemSharesElsewhere(bool sameChain) public {
        IAsyncVault vault = _testAsyncDeposit(sameChain);
        IShareToken share = IShareToken(vault.share());
        uint128 parked = assetToShare(USDC_AMOUNT_1) - 1;
        _member(INVESTOR_A);

        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(parked, INVESTOR_A, INVESTOR_A));
        _freeze(INVESTOR_A);
        _cancel(false, requestId, parked);

        vm.prank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.mint(parked, CLEAN, INVESTOR_A);
        assertEq(share.balanceOf(CLEAN), 0, "the cancelled shares stayed in the escrow");
    }

    /// @dev C-3 (sec-custody F4 and PoC2, async leg): a hook manager could freeze the vault, after which
    ///      every revocation through it reverted; cross-chain the hub consumed the order while the spoke
    ///      never settled. The freeze is now refused on the spoke, and the redeem settles.
    function testTheVaultCannotBeFrozenSoTheRedeemSettles() public {
        IAsyncVault vault = _testAsyncDeposit(false);
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        _member(INVESTOR_A);

        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A));

        vm.recordLogs();
        _freeze(address(vault));
        assertEq(_lastFailure(), IShareTokenHook.VaultCannotBeFrozen.selector, "the spoke refuses the freeze");
        assertFalse(s.redemptionRestrictionsHook.isFrozen(vault.share(), address(vault)), "vault not frozen");

        _fulfill(false, requestId, shares);
        assertEq(vault.pendingRedeemRequest(0, INVESTOR_A), 0, "the spoke settled it");
        assertEq(vault.maxWithdraw(INVESTOR_A), shareToAsset(shares), "the claim opened");
        assertEq(IShareToken(vault.share()).balanceOf(vault.escrow()), 0, "the parked shares were revoked");
    }

    /// @dev C-3, same-chain and with a freeze bit set before the exemption could see the vault: the
    ///      settlement used to revert inside the manager's own fulfil. The revocation leg ignores it.
    function testAPreexistingFreezeBitDoesNotBlockTheSameChainFulfil() public {
        IAsyncVault vault = _testAsyncDeposit(true);
        IShareToken share = IShareToken(vault.share());
        uint128 shares = assetToShare(USDC_AMOUNT_1);
        _member(INVESTOR_A);

        vm.prank(INVESTOR_A);
        RequestId requestId = RequestId.wrap(vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A));

        vm.prank(share.hook());
        share.setHookData(address(vault), bytes16(uint128(1)));
        assertTrue(s.redemptionRestrictionsHook.isFrozen(address(share), address(vault)), "freeze bit set");

        _fulfill(false, requestId, shares);
        assertEq(vault.pendingRedeemRequest(0, INVESTOR_A), 0, "settled");
        assertEq(vault.maxWithdraw(INVESTOR_A), shareToAsset(shares));
    }

    /// @dev Custody K-1 / wischli blocker 2 under RedemptionRestrictions (sec-custody F2): a non-member
    ///      holder exited through the instant lane, to a non-member receiver, though `requestRedeem`
    ///      refused it. The instant exit now passes the request's gate too.
    function testANonMemberCannotExitThroughTheInstantLane(bool sameChain) public {
        _setUpPool(sameChain);
        IAsyncVault vault = _instantVault();
        uint256 shares = _instantDeposit(vault, INVESTOR_A, USDC_AMOUNT_1);

        assertEq(vault.maxRedeem(INVESTOR_A), 0, "no capacity is advertised");
        vm.startPrank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.requestRedeem(shares, INVESTOR_A, INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.redeem(shares, CLEAN);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.withdraw(USDC_AMOUNT_1 / 2, INVESTOR_A);
        vm.stopPrank();
        assertEq(s.usdc.balanceOf(CLEAN), 0, "nothing was paid out");
    }

    /// @dev Blocker 2 under FullRestrictions: a holder whose membership lapsed is refused on
    ///      `requestRedeem`, and so now on `redeem(shares, self)` as well.
    function testALapsedMemberCannotExitThroughTheInstantLane() public {
        _setUpPool(true);
        _useHook(address(s.fullRestrictionsHook));
        IAsyncVault vault = _instantVault();
        _memberUntil(INVESTOR_A, uint64(block.timestamp + 1 hours));
        uint256 shares = _instantDeposit(vault, INVESTOR_A, USDC_AMOUNT_1);

        vm.warp(block.timestamp + 2 hours);
        _configurePrices(IntegrationConstants.assetPrice(), IntegrationConstants.sharePrice());

        assertEq(vault.maxRedeem(INVESTOR_A), 0, "no capacity is advertised");
        vm.prank(INVESTOR_A);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.redeem(shares, INVESTOR_A);

        _memberUntil(INVESTOR_A, uint64(block.timestamp + 1 hours));
        vm.prank(INVESTOR_A);
        vault.redeem(shares, INVESTOR_A);
        assertEq(IShareToken(vault.share()).balanceOf(INVESTOR_A), 0, "a renewed member exits");
    }

    /// @dev Blocker 2 under FreelyTransferable: a non-member who received shares by a free transfer
    ///      exited by naming a member as the receiver.
    function testANonMemberCannotExitByNamingAMemberReceiver() public {
        _setUpPool(true);
        _useHook(address(deployA.freelyTransferableHook()));
        IAsyncVault vault = _instantVault();
        _member(INVESTOR_A);
        uint256 shares = _instantDeposit(vault, INVESTOR_A, USDC_AMOUNT_1);

        IShareToken share = IShareToken(vault.share());
        vm.prank(INVESTOR_A);
        share.transfer(BOB, shares);

        vm.prank(BOB);
        vm.expectRevert(ITransferHook.TransferBlocked.selector);
        vault.redeem(shares, INVESTOR_A);
        assertEq(share.balanceOf(BOB), shares, "the shares stayed put");
    }
}
