// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IRequestPolicy} from "./interfaces/IVaultPlugins.sol";
import {IPerInvestorPolicy, IPerRequestPolicy, IPerPeriodPolicy} from "./interfaces/IRequestPolicies.sol";

import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";

/// @title  Per-Investor Request Policy
/// @notice Default request model: one bucket per controller per side, so repeat requests
///         accumulate into a single hub-side position. Cheapest in cross-chain messages.
/// @dev    The key is the controller, so the controller is always its bucket's sole owner: it keeps extending it
///         after a flush and reopens the same id once it retires. Request transfers are unsupported.
contract PerInvestorPolicy is IPerInvestorPolicy {
    using CastLib for address;

    bool public constant isBatched = false;
    uint256 public constant maxOpenBuckets = 1;
    bool public constant supportsTransfers = false;

    /// @inheritdoc IRequestPolicy
    function onRequest(address, address controller, address, bool, uint128) external pure returns (bytes32) {
        return controller.toBytes32();
    }

    /// @inheritdoc IRequestPolicy
    function isClosed(address, bytes32) external pure returns (bool) {
        return true;
    }
}

/// @title  Per-Request Policy
/// @notice Every request gets a fresh bucket, tracked and fulfilled individually, so a position
///         settles at its own price rather than blended into a window. Required for per-order
///         handling and for individually tradeable pending positions (drawdown funds).
contract PerRequestPolicy is IPerRequestPolicy {
    bool public constant isBatched = false;
    uint256 public constant maxOpenBuckets = 1;

    bool public immutable supportsTransfers;

    constructor(bool transfersEnabled_) {
        supportsTransfers = transfersEnabled_;
        emit PerRequestConfigured(transfersEnabled_);
    }

    /// @inheritdoc IRequestPolicy
    /// @dev The zero key: a fresh bucket for every request.
    function onRequest(address, address, address, bool, uint128) external pure returns (bytes32) {
        return 0;
    }

    /// @inheritdoc IRequestPolicy
    function isClosed(address, bytes32) external pure returns (bool) {
        return true;
    }
}

/// @title  Per-Period Request Policy
/// @notice Groups all requests within a time window into one shared bucket per side, sending one hub
///         message per window. The vault sends a closed window when the next one opens, or anyone can via
///         `flushRequest`. A claim folds the controller's latest windows, as many as the vault's `foldHorizon`;
///         anyone folds the rest through `foldRequest`. Unless the vault sets `foldHorizon`, it is `maxOpenBuckets`,
///         which is 1 without a notice: a claim then sees only the latest window, and each older one waits for a
///         keeper's `foldRequest`. A vault whose investors keep several windows unsettled sets it to that many.
/// @dev    Windows are numbered from 1: window `i` runs from `(i - 1) * window + offset` to `i * window + offset`, and
///         its key is `bytes32(i)`. A side with a notice puts a request made at `t` in the window that holds
///         `t + notice`, so with a notice shorter than the window that is a cutoff before each close. Several windows
///         of a side are then open at once, and a keeper flushes each closed one.
contract PerPeriodPolicy is IPerPeriodPolicy {
    bool public constant isBatched = true;
    bool public constant supportsTransfers = true;

    uint64 public immutable window;
    uint64 public immutable offset;
    uint64 public immutable redeemNotice;
    uint64 public immutable depositNotice;
    uint256 public immutable maxOpenBuckets;

    constructor(uint64 window_, uint64 offset_, uint64 depositNotice_, uint64 redeemNotice_) {
        require(offset_ < window_, InvalidOffset());
        window = window_;
        offset = offset_;
        depositNotice = depositNotice_;
        redeemNotice = redeemNotice_;

        // A request lands in the open window or one of the windows its notice spans, all open at once.
        uint256 notice = MathLib.max(depositNotice_, redeemNotice_);
        maxOpenBuckets = (notice + window_ - 1) / window_ + 1;
        emit PerPeriodConfigured(window_, offset_, depositNotice_, redeemNotice_);
    }

    /// @inheritdoc IRequestPolicy
    /// @dev The key of the window holding `block.timestamp` plus the side's notice.
    function onRequest(address, address, address, bool isDeposit, uint128) external view returns (bytes32) {
        return bytes32(_windowAt(block.timestamp + (isDeposit ? depositNotice : redeemNotice)));
    }

    /// @inheritdoc IRequestPolicy
    /// @dev A window is closed once it has ended. Zero, which names no window, never is.
    function isClosed(address, bytes32 key) external view returns (bool) {
        return key != 0 && uint256(key) < _windowAt(block.timestamp);
    }

    /// @dev The window holding time `t`.
    function _windowAt(uint256 t) internal view returns (uint256) {
        return (t - offset) / window + 1;
    }
}
