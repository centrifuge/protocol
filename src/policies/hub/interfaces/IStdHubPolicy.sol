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
    struct Entry {
        PoolId poolId;
        address caller;
        bytes4[] selectors;
    }

    /// @notice Policy configuration set at construction.
    /// @dev Two price guards with opposite disable sentinels: `maxAbsolutePriceDelta` + `thresholdPerSecond`
    ///      bound `updateSharePrice` (each `0` = off), `maxBrmPriceDeviation` bounds BRM call prices
    ///      (`type(uint128).max` = off, `0` = exact match).
    struct Config {
        uint48 delay;
        uint48 expiry;
        uint48 escalation;
        Entry[] allowlist;
        address navManager;
        bool onchainAccounting;
        uint128 thresholdPerSecond;
        uint128 maxBrmPriceDeviation;
        uint128 maxAbsolutePriceDelta;
        address simplePriceManager;
        address requestManager;
        address bridgingHook;
        address oracleValuation;
    }

    function hub() external view returns (IHub);
    function hubRegistry() external view returns (IHubRegistry);
    function multiAdapter() external view returns (IMultiAdapter);
    function shareClassManager() external view returns (IShareClassManager);
    function delay() external view returns (uint48);
    function expiry() external view returns (uint48);
    function escalation() external view returns (uint48);
    function thresholdPerSecond() external view returns (uint128);
    function maxBrmPriceDeviation() external view returns (uint128);
    function maxAbsolutePriceDelta() external view returns (uint128);
    function onchainAccounting() external view returns (bool);
    function navManager() external view returns (address);
    function simplePriceManager() external view returns (address);
    function requestManager() external view returns (address);
    function bridgingHook() external view returns (address);
    function oracleValuation() external view returns (address);
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
