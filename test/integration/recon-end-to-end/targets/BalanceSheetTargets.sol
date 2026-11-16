// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ERC20} from "../../../../src/misc/ERC20.sol";

import {AssetId} from "../../../../src/core/types/AssetId.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";

/// @notice Balance-sheet operations on pool A's spoke, each made by a caller drawn from the manager,
///         the auxiliary manager (whose role the fuzzer toggles) and an outsider, so authorization is
///         exercised on every one. Exact escrow and queue deltas are checked inline after each success.
abstract contract BalanceSheetTargets is BaseTargetFunctions, Properties {
    bytes32 internal constant REASON_BSM = keccak256("bsm");
    uint256 internal constant STRANGER_FUNDS = 1e6;

    struct EscrowState {
        uint128 total;
        uint128 reserved;
        uint128 queuedDeposits;
        uint128 queuedWithdrawals;
        uint128 otherTotal;
        uint128 otherQueuedDeposits;
        uint128 otherQueuedWithdrawals;
        int256 queuedShares;
    }

    //----------------------------------------------------------------------------------------------
    // Assets
    //----------------------------------------------------------------------------------------------

    function balanceSheet_deposit(uint256 callerSeed, bool cShare, uint128 amount) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);
        ERC20 asset = cShare ? ERC20(address(shareC)) : usdc;
        uint256 balance = asset.balanceOf(caller);
        if (balance == 0) {
            if (caller == BSM) return;
            // An unauthorized caller holds nothing, so the call would stop here and the refusal under test would
            // never run: give it USDC (tracked by `property_sum_of_balances`) and deposit that
            cShare = false;
            asset = usdc;
            balance = STRANGER_FUNDS;
            usdc.mint(caller, STRANGER_FUNDS);
        }
        amount = uint128(between(amount, 0, balance));

        EscrowState memory before_ = _state(cShare);
        vm.prank(caller);
        asset.approve(address(spoke), amount);
        (bool success,) =
            _callAs(caller, address(spoke), abi.encodeCall(spoke.deposit, (poolA, scA, address(asset), 0, amount)));
        if (!_privileged(caller, success, "balanceSheet_deposit")) return;
        _checkMoved(before_, _state(cShare), int256(uint256(amount)), 0, true, amount);
    }

    /// @dev Credits assets that already reached the escrow, the use it is meant for: the amount is
    ///      minted there first, so the fuzzer explores reconciliation rather than over-crediting.
    ///      One call in eight credits as much as the types and the accounts allow (see `_hugeAssets`).
    function balanceSheet_noteDeposit(uint256 callerSeed, uint128 amount, uint8 mode)
        public
        updateGhosts(OpType.MANAGER)
    {
        address caller = _caller(callerSeed);
        amount = uint128(between(amount, 0, mode % 8 == 0 ? _hugeAssets() : 1_000_000 * ONE_ASSET));
        EscrowState memory before_ = _state(false);
        (bool success,) =
            _callAs(caller, address(spoke), abi.encodeCall(spoke.noteDeposit, (poolA, scA, address(usdc), 0, amount)));
        if (!_privileged(caller, success, "balanceSheet_noteDeposit")) return;
        usdc.mint(address(_escrow(poolA)), amount);
        _checkMoved(before_, _state(false), int256(uint256(amount)), 0, true, amount);
    }

    /// @dev Tries past the available balance as well: reserved funds must never come out this way.
    function balanceSheet_withdraw(uint256 callerSeed, bool cShare, uint128 amount)
        public
        updateGhosts(OpType.MANAGER)
    {
        address caller = _caller(callerSeed);
        address asset = cShare ? address(shareC) : address(usdc);
        uint128 available = spoke.availableBalanceOf(poolA, scA, asset, 0);
        amount = uint128(between(amount, 0, uint256(available) + ONE_ASSET));

        EscrowState memory before_ = _state(cShare);
        if (!_privileged(caller, _withdrawAs(caller, asset, amount), "balanceSheet_withdraw")) return;
        lte(amount, available, "withdraw took more than total - reserved");
        _checkMoved(before_, _state(cShare), -int256(uint256(amount)), 0, false, amount);
    }

    /// @dev Over-reserves (past the escrow's total, ahead of arrival) for one `over` call in four: the state
    ///      holds back redeem claims and closes the instant redeem lane until unreserved, so it is kept rare.
    function balanceSheet_reserve(uint256 callerSeed, uint128 amount, bool over) public updateGhosts(OpType.MANAGER) {
        over = over && amount % 4 == 0;
        address caller = _caller(callerSeed);
        uint128 available = spoke.availableBalanceOf(poolA, scA, address(usdc), 0);
        amount = over
            ? uint128(uint256(available) + 1 + between(amount, 0, 1_000 * ONE_ASSET))
            : uint128(between(amount, 0, available));

        EscrowState memory before_ = _state(false);
        bytes memory data = abi.encodeCall(spoke.reserve, (poolA, scA, address(usdc), 0, amount, BSM, REASON_BSM));
        (bool success,) = _callAs(caller, address(spoke), data);
        if (!_privileged(caller, success, "balanceSheet_reserve")) return;
        ghost_bsmReserved += amount;
        _checkMoved(before_, _state(false), 0, int256(uint256(amount)), false, amount);
    }

    function balanceSheet_unreserve(uint256 callerSeed, uint128 amount) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);
        amount = uint128(between(amount, 0, ghost_bsmReserved));

        EscrowState memory before_ = _state(false);
        bytes memory data = abi.encodeCall(spoke.unreserve, (poolA, scA, address(usdc), 0, amount, BSM, REASON_BSM));
        (bool success,) = _callAs(caller, address(spoke), data);
        if (!_privileged(caller, success, "balanceSheet_unreserve")) return;
        ghost_bsmReserved -= amount;
        _checkMoved(before_, _state(false), 0, -int256(uint256(amount)), true, amount);
    }

    /// @dev The hub decrease was queued when the funds were reserved, so this queues nothing.
    function balanceSheet_withdrawReserved(uint256 callerSeed, uint128 amount) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);
        amount = uint128(between(amount, 0, ghost_bsmReserved));

        EscrowState memory before_ = _state(false);
        bytes memory data =
            abi.encodeCall(spoke.withdrawReserved, (poolA, scA, address(usdc), 0, caller, amount, BSM, REASON_BSM));
        (bool success,) = _callAs(caller, address(spoke), data);
        if (!_privileged(caller, success, "balanceSheet_withdrawReserved")) return;
        ghost_bsmReserved -= amount;
        EscrowState memory after_ = _state(false);
        eq(after_.total + amount, before_.total, "withdrawReserved: total != before - amount");
        eq(after_.reserved + amount, before_.reserved, "withdrawReserved: reserved != before - amount");
        eq(after_.queuedDeposits, before_.queuedDeposits, "withdrawReserved queued a deposit");
        eq(after_.queuedWithdrawals, before_.queuedWithdrawals, "withdrawReserved queued a withdrawal");
        _checkIsolated(before_, after_);
    }

    /// @dev A manager names a vault as the reserver and releases what it reserved for one of its requests: allowed,
    ///      the manager answers for the pool's funds. The escrow gives up exactly the amount, from the total, the
    ///      reserved sum and that reservation, and nothing is queued for the hub, which stopped counting these
    ///      assets when they were reserved. The funds are then put back under the same reserver and reason, so the
    ///      vault's request stays backed for the properties and flows that follow.
    struct Release {
        address caller;
        address vault;
        bytes32 reason;
        uint128 amount;
        uint128 reserved;
    }

    function bs_withdrawVaultReserved(uint256 callerSeed, uint256 reqSeed, uint128 amount)
        public
        updateGhosts(OpType.MANAGER)
    {
        if (reqs.length == 0) return;
        Req memory r = reqs[reqSeed % reqs.length];
        if (!r.isDeposit) return;
        Release memory rel;
        rel.caller = _caller(callerSeed);
        rel.vault = address(vaults[r.vault]);
        rel.reason = _depositReason(uint96(r.requestId));
        rel.reserved = _escrow(poolA).reservedBy(scA, rel.vault, rel.reason, address(usdc), 0);
        rel.amount = uint128(between(amount, 0, rel.reserved));
        _releaseVaultReservation(rel);
    }

    function _releaseVaultReservation(Release memory rel) internal {
        EscrowState memory before_ = _state(false);
        (bool success,) = _callAs(rel.caller, address(spoke), _releaseCall(rel));
        if (!_privileged(rel.caller, success, "bs_withdrawVaultReserved")) return;
        _checkReleased(rel, before_, _state(false));
        if (rel.amount != 0) _putBack(rel);
    }

    function _releaseCall(Release memory rel) internal view returns (bytes memory) {
        return abi.encodeCall(
            spoke.withdrawReserved, (poolA, scA, address(usdc), 0, rel.caller, rel.amount, rel.vault, rel.reason)
        );
    }

    function _checkReleased(Release memory rel, EscrowState memory before_, EscrowState memory after_) internal {
        eq(after_.total + rel.amount, before_.total, "withdrawReserved on a vault's reason: total != before - amount");
        eq(
            after_.reserved + rel.amount,
            before_.reserved,
            "withdrawReserved on a vault's reason: reserved != before - amount"
        );
        eq(
            uint256(_escrow(poolA).reservedBy(scA, rel.vault, rel.reason, address(usdc), 0)) + rel.amount,
            rel.reserved,
            "withdrawReserved did not take the amount from the vault's reservation"
        );
        eq(after_.queuedDeposits, before_.queuedDeposits, "withdrawReserved on a vault's reason queued a deposit");
        eq(
            after_.queuedWithdrawals,
            before_.queuedWithdrawals,
            "withdrawReserved on a vault's reason queued a withdrawal"
        );
    }

    /// @dev The released funds go back into the escrow, are noted and reserved again under the vault's own key.
    function _putBack(Release memory rel) internal {
        vm.prank(rel.caller);
        usdc.transfer(address(_escrow(poolA)), rel.amount);
        _callAs(BSM, address(spoke), abi.encodeCall(spoke.noteDeposit, (poolA, scA, address(usdc), 0, rel.amount)));
        _callAs(
            BSM,
            address(spoke),
            abi.encodeCall(spoke.reserve, (poolA, scA, address(usdc), 0, rel.amount, rel.vault, rel.reason))
        );
    }

    //----------------------------------------------------------------------------------------------
    // Shares
    //----------------------------------------------------------------------------------------------

    /// @dev Issues to the escrow or to the manager itself; escrow-held issuance is the only share float
    ///      the manager may later take out with `withdrawShares`.
    ///      One call in eight issues up to a quarter of `uint128.max`, which the share queue and the supply must
    ///      take or refuse, never wrap.
    function balanceSheet_issue(uint256 callerSeed, uint128 shares, bool toEscrow, uint8 mode)
        public
        updateGhosts(OpType.MANAGER)
    {
        address caller = _caller(callerSeed);
        shares = uint128(between(shares, 0, mode % 8 == 0 ? type(uint128).max / 4 : 1_000_000 * ONE_SHARE));
        address to = toEscrow ? address(_escrow(poolA)) : caller;

        EscrowState memory before_ = _state(false);
        (bool success,) = _callAs(caller, address(spoke), abi.encodeCall(spoke.issue, (poolA, scA, to, shares)));
        if (!_privileged(caller, success, "balanceSheet_issue")) return;
        if (toEscrow) ghost_bsmEscrowShares += shares;
        _checkShares(before_, int256(uint256(shares)));
    }

    function balanceSheet_revoke(uint256 callerSeed, uint128 shares) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);
        shares = uint128(between(shares, 0, shareA.balanceOf(caller)));

        EscrowState memory before_ = _state(false);
        vm.prank(caller);
        shareA.approve(address(spoke), shares);
        (bool success,) = _callAs(caller, address(spoke), abi.encodeCall(spoke.revoke, (poolA, scA, shares)));
        if (!_privileged(caller, success, "balanceSheet_revoke")) return;
        _checkShares(before_, -int256(uint256(shares)));
    }

    /// @dev Bounded by the escrow shares the manager issued itself, so it cannot strand a claim.
    function balanceSheet_withdrawShares(uint256 callerSeed, uint128 shares) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);
        shares = uint128(between(shares, 0, ghost_bsmEscrowShares));
        uint256 escrowBefore = shareA.balanceOf(address(_escrow(poolA)));
        EscrowState memory before_ = _state(false);

        bytes memory data = abi.encodeCall(spoke.withdrawShares, (poolA, scA, caller, shares));
        (bool success,) = _callAs(caller, address(spoke), data);
        if (!_privileged(caller, success, "balanceSheet_withdrawShares")) return;
        ghost_bsmEscrowShares -= shares;
        eq(escrowBefore, shareA.balanceOf(address(_escrow(poolA))) + shares, "withdrawShares moved the wrong amount");
        t(_state(false).queuedShares == before_.queuedShares, "withdrawShares touched the share queue");
    }

    //----------------------------------------------------------------------------------------------
    // Submissions
    //----------------------------------------------------------------------------------------------

    /// @dev Flushes one asset queue: it is cleared, the other asset queue and the share delta are not,
    ///      one nonce is consumed, and the hub holding then matches the escrow.
    function balanceSheet_submitQueuedAssets(uint256 callerSeed, bool cShare) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);
        AssetId assetId = cShare ? cShareId : usdcId;
        EscrowState memory before_ = _state(cShare);
        (,,, uint64 nonce) = snapshotQueue.queuedShares(poolA, scA);

        bytes memory data = abi.encodeCall(spoke.submitQueuedAssets, (poolA, scA, assetId, 0, REFUND));
        (bool success,) = _callAs(caller, address(spoke), data);
        if (!_privileged(caller, success, "balanceSheet_submitQueuedAssets")) return;
        ghost_shareQueueFlushes++;

        EscrowState memory after_ = _state(cShare);
        (,,, uint64 nonceAfter) = snapshotQueue.queuedShares(poolA, scA);
        eq(after_.queuedDeposits + after_.queuedWithdrawals, 0, "submitQueuedAssets left the queue non-empty");
        eq(after_.otherQueuedDeposits, before_.otherQueuedDeposits, "submitQueuedAssets cleared another asset");
        eq(after_.otherQueuedWithdrawals, before_.otherQueuedWithdrawals, "submitQueuedAssets cleared another asset");
        t(after_.queuedShares == before_.queuedShares, "submitQueuedAssets touched the share delta");
        eq(nonceAfter, nonce + 1, "submitQueuedAssets did not consume exactly one nonce");
        property_hubHoldingMatchesEscrowAccounted();
    }

    /// @dev Flushes the basin's liability queue: the hub's holding of the debt then matches the escrow.
    function balanceSheet_submitLiability(uint256 callerSeed) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);

        bytes memory data = abi.encodeCall(spoke.submitQueuedAssets, (poolA, scA, basinLiabilityId, 0, REFUND));
        (bool success,) = _callAs(caller, address(spoke), data);
        if (!_privileged(caller, success, "balanceSheet_submitLiability")) return;
        ghost_shareQueueFlushes++;

        (uint128 booked,) = _escrow(poolA).holding(scA, address(accountingToken), _basinLiabilityTokenId());
        eq(holdings.amount(poolA, scA, basinLiabilityId), booked, "hub liability != escrow liability");
    }

    /// @dev Flushes the share delta: the hub's issuance moves by exactly it and then equals the supply.
    function balanceSheet_submitQueuedShares(uint256 callerSeed) public updateGhosts(OpType.MANAGER) {
        address caller = _caller(callerSeed);
        EscrowState memory before_ = _state(false);
        uint128 issuance = shareClassManager.issuance(poolA, scA, CENTRIFUGE_ID);
        (,,, uint64 nonce) = snapshotQueue.queuedShares(poolA, scA);

        bytes memory data = abi.encodeCall(spoke.submitQueuedShares, (poolA, scA, 0, REFUND));
        (bool success,) = _callAs(caller, address(spoke), data);
        if (!_privileged(caller, success, "balanceSheet_submitQueuedShares")) return;
        ghost_shareQueueFlushes++;

        EscrowState memory after_ = _state(false);
        (,,, uint64 nonceAfter) = snapshotQueue.queuedShares(poolA, scA);
        uint128 issuanceAfter = shareClassManager.issuance(poolA, scA, CENTRIFUGE_ID);
        t(after_.queuedShares == 0, "submitQueuedShares left a share delta");
        t(
            int256(uint256(issuanceAfter)) - int256(uint256(issuance)) == before_.queuedShares,
            "hub issuance moved by other than the queued delta"
        );
        eq(issuanceAfter, shareA.totalSupply(), "hub issuance != share supply after submission");
        // The networks are this one and the one a bridged transfer moves issuance to
        eq(
            shareClassManager.totalIssuance(poolA, scA),
            uint256(issuanceAfter) + shareClassManager.issuance(poolA, scA, REMOTE_ID),
            "total issuance != sum of network issuance"
        );
        eq(after_.queuedDeposits, before_.queuedDeposits, "submitQueuedShares touched an asset queue");
        eq(nonceAfter, nonce + 1, "submitQueuedShares did not consume exactly one nonce");
    }

    //----------------------------------------------------------------------------------------------
    // Fund of funds and the basin
    //----------------------------------------------------------------------------------------------

    /// @dev The manager puts pool A's idle USDC into pool C through its instant vault and parks the shares
    ///      in pool A's escrow, which is what the liquidity route later redeems on demand.
    function bsm_investInUnderlying(uint128 amount) public updateGhosts(OpType.MANAGER) {
        uint128 available = spoke.availableBalanceOf(poolA, scA, address(usdc), 0);
        uint256 capacity = vaultC.maxDeposit(BSM);
        amount = uint128(between(amount, 0, available < capacity ? available : capacity));
        if (amount == 0) return;

        vm.prank(BSM);
        spoke.withdraw(poolA, scA, address(usdc), 0, BSM, amount);
        vm.prank(BSM);
        usdc.approve(address(vaultC), amount);
        uint256 balance = shareC.balanceOf(BSM);
        vm.prank(BSM);
        try vaultC.deposit(amount, BSM) {
            uint128 shares = uint128(shareC.balanceOf(BSM) - balance);
            vm.prank(BSM);
            shareC.approve(address(spoke), shares);
            vm.prank(BSM);
            spoke.deposit(poolA, scA, address(shareC), 0, shares);
            _ok("bsm_investInUnderlying");
        } catch {
            _reverted("bsm_investInUnderlying");
        }
    }

    /// @dev Settles what the basin vault drew, which reopens its credit line, up to what the manager holds.
    function bsm_repayBasin(uint128 amount) public updateGhosts(OpType.MANAGER) {
        uint256 receivable = basinRoute.receivable(address(vaults[3]));
        uint256 balance = usdc.balanceOf(BSM);
        amount = uint128(between(amount, 0, receivable < balance ? receivable : balance));
        if (amount == 0) return;
        vm.prank(BSM);
        usdc.approve(address(basinRoute), amount);
        vm.prank(BSM);
        basinRoute.repay(address(vaults[3]), amount);
        _ok("bsm_repayBasin");
    }

    /// @dev What the venue advertises and what it holds are set apart, so a quote can be dishonoured.
    function basin_advertise(uint256 amount) public updateGhosts(OpType.MANAGER) {
        basin.advertise(between(amount, 0, 2 * usdc.balanceOf(address(basin))));
        _ok("basin_advertise");
    }

    //----------------------------------------------------------------------------------------------
    // Internal
    //----------------------------------------------------------------------------------------------

    function _withdrawAs(address caller, address asset, uint128 amount) internal returns (bool success) {
        (success,) =
            _callAs(caller, address(spoke), abi.encodeCall(spoke.withdraw, (poolA, scA, asset, 0, caller, amount)));
    }

    function _caller(uint256 seed) internal pure returns (address) {
        uint256 pick = seed % 8;
        return pick < 6 ? BSM : pick == 6 ? AUX_MANAGER : OUTSIDER;
    }

    /// @dev Records authorization on every attempt and returns whether the call went through.
    function _privileged(address caller, bool success, bytes32 action) internal returns (bool) {
        if (!success) {
            _reverted(action);
            return false;
        }
        bool authorized = spoke.wards(caller) == 1 || spokeRegistry.manager(poolA, caller);
        if (!authorized) ghost_unauthorizedSuccess++;
        if (caller == AUX_MANAGER && !auxIsManager) ghost_callsAfterRevocation++;
        ghost_privilegedOperationCount++;
        ghost_lastAuthorizedCaller = caller;
        _ok(action);
        return true;
    }

    function _state(bool cShare) internal view returns (EscrowState memory s) {
        (address asset, address other) = cShare ? (address(shareC), address(usdc)) : (address(usdc), address(shareC));
        (AssetId assetId, AssetId otherId) = cShare ? (cShareId, usdcId) : (usdcId, cShareId);
        (s.total, s.reserved) = _escrow(poolA).holding(scA, asset, 0);
        (s.otherTotal,) = _escrow(poolA).holding(scA, other, 0);
        (s.queuedDeposits, s.queuedWithdrawals) = snapshotQueue.queuedAssets(poolA, scA, assetId);
        (s.otherQueuedDeposits, s.otherQueuedWithdrawals) = snapshotQueue.queuedAssets(poolA, scA, otherId);
        (uint128 delta, bool isPositive,,) = snapshotQueue.queuedShares(poolA, scA);
        s.queuedShares = _signed(delta, isPositive);
    }

    /// @dev Exact deltas: `total` and `reserved` by what was asked, the hub-facing queue in the direction
    ///      of the change to the accounted balance and by exactly the amount, zero amounts queue nothing.
    function _checkMoved(
        EscrowState memory before_,
        EscrowState memory after_,
        int256 totalDelta,
        int256 reservedDelta,
        bool isIncrease,
        uint128 amount
    ) internal {
        t(int256(uint256(after_.total)) - int256(uint256(before_.total)) == totalDelta, "escrow total moved wrongly");
        t(
            int256(uint256(after_.reserved)) - int256(uint256(before_.reserved)) == reservedDelta,
            "escrow reserved moved wrongly"
        );
        eq(
            isIncrease ? after_.queuedDeposits : after_.queuedWithdrawals,
            (isIncrease ? before_.queuedDeposits : before_.queuedWithdrawals) + amount,
            "queued delta != amount"
        );
        eq(
            isIncrease ? after_.queuedWithdrawals : after_.queuedDeposits,
            isIncrease ? before_.queuedWithdrawals : before_.queuedDeposits,
            "the opposite queue moved"
        );
        _checkIsolated(before_, after_);
    }

    function _checkIsolated(EscrowState memory before_, EscrowState memory after_) internal {
        eq(after_.otherTotal, before_.otherTotal, "another asset's holding moved");
        eq(after_.otherQueuedDeposits, before_.otherQueuedDeposits, "another asset's queue moved");
        eq(after_.otherQueuedWithdrawals, before_.otherQueuedWithdrawals, "another asset's queue moved");
        t(after_.queuedShares == before_.queuedShares, "an asset operation touched the share queue");
    }

    function _checkShares(EscrowState memory before_, int256 delta) internal {
        t(_state(false).queuedShares - before_.queuedShares == delta, "share queue moved by other than the amount");
    }
}
