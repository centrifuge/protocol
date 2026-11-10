// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {IHub} from "../../../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {IHubPolicy} from "../../../core/utils/interfaces/IPolicy.sol";
import {IHubRegistry} from "../../../core/hub/interfaces/IHubRegistry.sol";
import {IMultiAdapter} from "../../../core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../../core/hub/interfaces/IShareClassManager.sol";

interface IStdHubPolicy is IHubPolicy {
    error OnchainAccountingOnly();
    error CallerNotAllowed();
    error InvalidConfig();

    /// @notice Confines a caller to a fixed set of selectors for a pool. A (pool, caller) with any
    ///         entry may invoke only its listed selectors; everything else is blocked outright. Set
    ///         once at construction.
    /// @dev    Denies the instant, capability-reducing selectors too: a confined caller that must be able
    ///         to veto or revoke needs `cancelAuthorization` / `unauthorizeSpokeCall` listed explicitly.
    struct Entry {
        PoolId poolId;
        address caller;
        bytes4[] selectors;
    }

    /// @notice Policy configuration set at construction.
    /// @dev Optional per pool: `isRestrictionUpdateInstant` makes every `updateRestriction` instant for a manager, with no
    ///      canonical-Freeze check and no sentinel veto. Price guards with opposite disable sentinels:
    ///      `maxAbsolutePriceDelta` + `thresholdPerSecond` bound `updateSharePrice` (each `0` = off),
    ///      `maxFulfillPriceDeviation` bounds the OrderBook's fulfillment prices (`type(uint128).max` = off, `0` =
    ///      exact match). `maxFeeBps` bounds the OrderBook's fill-vs-net fee and `maxRebateBps` its fulfillment
    ///      rebate, in basis points of the fill (at most 10_000, or `type(uint128).max` = off). A cancellation can
    ///      never rebate.
    struct Config {
        uint48 delay;
        uint48 expiry;
        uint48 escalation;
        Entry[] allowlist;
        address navManager;
        bool onchainAccounting;
        bool isRestrictionUpdateInstant;
        uint128 thresholdPerSecond;
        uint128 maxAbsolutePriceDelta;
        address simplePriceManager;
        address bridgingHook;
        address spokeOracle;
        address oracleValuation;
        address orderBook;
        uint128 maxFulfillPriceDeviation;
        uint128 maxFeeBps;
        uint128 maxRebateBps;
    }

    function hub() external view returns (IHub);
    function hubRegistry() external view returns (IHubRegistry);
    function multiAdapter() external view returns (IMultiAdapter);
    function shareClassManager() external view returns (IShareClassManager);
    function delay() external view returns (uint48);
    function expiry() external view returns (uint48);
    function escalation() external view returns (uint48);
    function thresholdPerSecond() external view returns (uint128);
    function maxAbsolutePriceDelta() external view returns (uint128);
    function onchainAccounting() external view returns (bool);
    function isRestrictionUpdateInstant() external view returns (bool);
    function navManager() external view returns (address);
    function simplePriceManager() external view returns (address);
    function bridgingHook() external view returns (address);
    function spokeOracle() external view returns (address);
    function oracleValuation() external view returns (address);
    function orderBook() external view returns (address);
    function maxFulfillPriceDeviation() external view returns (uint128);
    function maxFeeBps() external view returns (uint128);
    function maxRebateBps() external view returns (uint128);
    function lastPriceUpdate(PoolId poolId, ShareClassId scId) external view returns (uint64);
    function restricted(PoolId poolId, address caller) external view returns (bool);
    function allowed(PoolId poolId, address caller, bytes4 selector) external view returns (bool);
}

interface IStdHubPolicyFactory {
    event DeployHubPolicy(address indexed policy);

    function hub() external view returns (IHub);
    function multiAdapter() external view returns (IMultiAdapter);
    function shareClassManager() external view returns (IShareClassManager);

    function newHubPolicy(IStdHubPolicy.Config memory config) external returns (IStdHubPolicy);
    function previewHubPolicy(IStdHubPolicy.Config memory config) external view returns (address);
}
