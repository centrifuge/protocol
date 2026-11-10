// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {FlowTargets} from "./FlowTargets.sol";

import {D18, d18} from "../../../../src/misc/types/D18.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";

/// @notice The vault oracle's runtime states: the pool pausing it through the Envoy, prices aging past
///         `maxAge`, and the two prices notified more than `maxSkew` apart. `property_oracleVerdict` and
///         `property_invalidPriceClosesInstantLane` check every state these reach.
abstract contract OracleTargets is FlowTargets {
    uint8 internal constant ASYNC_VAULT = 0;

    /// @dev Pausing invalidates the price at once; unpausing restores whatever age and skew allow. One
    ///      seed in four pauses, so the instant lane is open for most of a run rather than half of it.
    function oracle_setPaused(uint256 seed) public updateGhosts(OpType.TERMS) {
        bool paused = seed % 4 == 0;
        _setOraclePaused(paused);
        t(spokeOracle.isPaused(poolA) == paused, "the pause did not land");
        if (paused) t(!_oracleValid(), "a paused oracle reported a valid price");
        _ok("oracle_setPaused");
    }

    /// @dev Time passes beyond `maxAge` with no notification: both prices go stale.
    function oracle_stale(uint256 secs) public updateGhosts(OpType.PRICE) {
        vm.warp(block.timestamp + ORACLE_MAX_AGE + between(secs, 1, 1 days));
        t(!_oracleValid(), "a price older than maxAge reported valid");
        _ok("oracle_stale");
    }

    /// @dev Only one of the two prices is notified, more than `maxSkew` after the other: each may be
    ///      fresh, the pair is not.
    function oracle_skew(uint256 secs, bool shareSide) public updateGhosts(OpType.PRICE) {
        vm.warp(block.timestamp + between(secs, ORACLE_MAX_SKEW + 1, ORACLE_MAX_AGE));
        if (shareSide) {
            (D18 pps,) = shareClassManager.pricePoolPerShare(poolA, scA);
            _fm();
            hub.updateSharePrice(poolA, scA, pps, uint64(block.timestamp));
            _fm();
            hub.notifySharePrice(poolA, scA, CENTRIFUGE_ID, REFUND);
        } else {
            _fm();
            hub.notifyAssetPrice(poolA, scA, usdcId, REFUND);
        }
        t(!_oracleValid(), "prices notified more than maxSkew apart reported valid");
        _ok("oracle_skew");
    }

    /// @dev Both pools' prices re-notified at their current values, without moving time.
    function oracle_refresh() public updateGhosts(OpType.PRICE) {
        (D18 pps,) = shareClassManager.pricePoolPerShare(poolA, scA);
        _pushPrices(poolA, scA, pps);
        _pushPrices(poolC, scC, d18(1, 1));
        t(_oracleVerdict() == !spokeOracle.isPaused(poolA), "fresh, coherent prices reported invalid");
        _ok("oracle_refresh");
    }

    /// @dev From a valid price: pausing closes the instant lane and unpausing reopens it exactly as it
    ///      was; then, paused again, a whole async deposit cycle must still complete, since requests,
    ///      settlement and claims price from the hub and the ledger rather than from the oracle.
    function oracle_pauseRoundTrip(uint256 actorSeed, uint256 amount, uint256 fillSeed)
        public
        updateGhosts(OpType.MANAGER)
    {
        // Under the hub policy each pause waits for its authorization: wait for both now, so no time passes between
        // the views compared (a membership lapsing in that hour would move them)
        _authorizeManagerCall(poolA, address(spokeOracle), abi.encode(true));
        _authorizeManagerCall(poolA, address(spokeOracle), abi.encode(false));
        if (!_oracleValid()) return;
        bytes32 open = _instantViews();
        uint256 openedAt = block.timestamp;

        _setOraclePaused(true);
        property_invalidPriceClosesInstantLane();
        _setOraclePaused(false);
        // Under the hub policy each pause waits out a delay that moves time, which can lapse a membership or age
        // the prices: what time changed is not what unpausing failed to restore
        if (block.timestamp == openedAt) t(_instantViews() == open, "unpausing did not restore the instant lane");

        address actor = _unfrozen(actorSeed);
        uint256 balance = usdc.balanceOf(actor);
        // The cycle needs a fill the OrderBook accepts, which a zero price or a fee that takes all of a smallest fill refuses
        bool live = balance >= _dust(true) && _healthy(vaults[ASYNC_VAULT], actor) && !hubPolicyInstalled
            && _fillBuysShares(_dust(true));
        _setOraclePaused(true);
        if (live) {
            bool completed = _depositCycle(actor, ASYNC_VAULT, between(amount, _dust(true), balance), fillSeed);
            t(completed, "an async deposit cycle failed while the oracle was paused");
            _ok("async_onInvalidPrice");
        }
        _setOraclePaused(false);
        _ok("oracle_pauseRoundTrip");
    }

    function _setOraclePaused(bool paused) internal {
        _managerCall(poolA, address(spokeOracle), abi.encode(paused));
    }

    /// @dev Every instant capacity and preview the lane answers, hashed.
    function _instantViews() internal view returns (bytes32 h) {
        for (uint256 v = 2; v < 4; v++) {
            IAsyncVault vault = vaults[v];
            h = keccak256(
                abi.encode(
                    h,
                    vault.previewDeposit(ONE_ASSET),
                    vault.previewMint(ONE_SHARE),
                    vault.previewWithdraw(ONE_ASSET),
                    vault.previewRedeem(ONE_SHARE)
                )
            );
            for (uint256 a; a < actors.length; a++) {
                address actor = actors[a];
                h = keccak256(
                    abi.encode(
                        h,
                        vault.maxDeposit(actor),
                        vault.maxMint(actor),
                        vault.maxWithdraw(actor),
                        vault.maxRedeem(actor)
                    )
                );
            }
        }
    }
}
