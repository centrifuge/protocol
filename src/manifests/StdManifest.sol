// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStdManifest} from "./interfaces/IStdManifest.sol";

import {D18} from "../misc/types/D18.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {IHub} from "../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IManifest} from "../core/hub/interfaces/IManifest.sol";
import {IAdapter} from "../core/messaging/interfaces/IAdapter.sol";
import {IHubRegistry} from "../core/hub/interfaces/IHubRegistry.sol";
import {IMultiAdapter} from "../core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../core/hub/interfaces/IShareClassManager.sol";

import {IOnOffRamp} from "../managers/spoke/interfaces/IOnOffRamp.sol";

/// @title  Standard Manifest
/// @notice Default policy + authorization registry installed on the Hub via {IHub.setManifest}.
///
///         The Hub calls {enforce} on every guarded manager method. In-policy calls (delay 0) run
///         synchronously; out-of-policy calls must be pre-authorized via {authorize} and matured past
///         the delay, leaving sentinels a veto window via {cancelAuthorization}. Matching is by exact
///         calldata keyed on (poolId, calldata) and consumed on use; one instance can serve many
///         pools. Only an out-of-policy call may be authorized, and a matured authorization is
///         executable only within `expiry` (then it fails closed), so it can neither be banked while
///         cheap nor held until the baseline has drifted.
///
///         Two delay tiers: `delay` for every out-of-policy action, and the longer `escalation` only
///         for replacing the manifest (the gravest action, since a malicious swap disables all policy).
///         See {_classify} for the full per-selector policy.
///
///         A caller may additionally be confined to a fixed set of selectors via the construction-time
///         allowlist: a listed caller can invoke only its selectors (anything else is blocked outright),
///         so a narrow keeper stays low-stakes even if its key leaks. The value guards still bound how
///         far each permitted call may move things.
contract StdManifest is IStdManifest {
    using BytesLib for bytes;

    // Dependencies
    IHub public immutable hub;
    address public immutable navManager;
    IHubRegistry public immutable hubRegistry;
    IMultiAdapter public immutable multiAdapter;
    address public immutable simplePriceManager;
    IShareClassManager public immutable shareClassManager;

    // Policy
    uint48 public immutable delay;
    uint48 public immutable expiry;
    uint48 public immutable escalation;
    uint128 public immutable maxPriceDelta;
    bool public immutable onchainAccounting;
    uint128 public immutable thresholdPerSecond;

    // State
    mapping(bytes32 authId => uint48 validAfter) public authorizedAfter;
    mapping(PoolId => mapping(ShareClassId => uint64)) public lastPriceUpdate;
    mapping(PoolId poolId => mapping(address caller => bool)) public restricted;
    mapping(PoolId poolId => mapping(address caller => mapping(bytes4 selector => bool))) public allowed;

    constructor(IHub hub_, IMultiAdapter multiAdapter_, IShareClassManager shareClassManager_, Config memory config) {
        // Dependencies
        hub = hub_;
        navManager = config.navManager;
        hubRegistry = hub_.hubRegistry();
        multiAdapter = multiAdapter_;
        simplePriceManager = config.simplePriceManager;
        shareClassManager = shareClassManager_;

        // Policy
        delay = config.delay;
        expiry = config.expiry;
        escalation = config.escalation;
        maxPriceDelta = config.maxPriceDelta;
        onchainAccounting = config.onchainAccounting;
        thresholdPerSecond = config.thresholdPerSecond;

        for (uint256 i; i < config.allowlist.length; i++) {
            Entry memory entry = config.allowlist[i];
            restricted[entry.poolId][entry.caller] = true;
            for (uint256 j; j < entry.selectors.length; j++) {
                allowed[entry.poolId][entry.caller][entry.selectors[j]] = true;
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Authorize flow
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManifest
    function enforce(PoolId poolId, address caller, bytes calldata data) external {
        require(msg.sender == address(hub), NotHub());
        (bytes4 selector, bytes calldata payload) = data.decodeCall();

        if (_classify(poolId, caller, selector, payload) != 0) {
            bytes32 authId = _authId(poolId, data);
            uint48 validAfter = authorizedAfter[authId];
            // Matured and not yet expired: a stale auth fails closed, so it can't be fired much later
            // (once the baseline has drifted) with no fresh veto window.
            require(
                validAfter != 0 && block.timestamp >= validAfter && block.timestamp <= uint256(validAfter) + expiry,
                Unauthorized()
            );
            delete authorizedAfter[authId];
        }

        // Anchor the share-price baseline to this executed update (never from authorize/cancel), so
        // the rate guard measures from actual price changes.
        if (selector == IHub.updateSharePrice.selector) {
            (, ShareClassId scId,,) = abi.decode(payload, (PoolId, ShareClassId, D18, uint64));
            lastPriceUpdate[poolId][scId] = uint64(block.timestamp);
        }
    }

    /// @inheritdoc IManifest
    function authorize(PoolId poolId, bytes calldata data) external {
        require(hubRegistry.manager(poolId, msg.sender), NotManager());

        // Only an out-of-policy call may be authorized; an in-policy one would mature immediately and
        // could be banked while cheap, then fired later once the same calldata is out of policy.
        (bytes4 selector, bytes calldata payload) = data.decodeCall();
        uint48 delaySeconds = _classify(poolId, msg.sender, selector, payload);
        require(delaySeconds != 0, InPolicy());

        // Reject re-authorizing a call that already has an authorization: overwriting would silently
        // reset its maturity clock (and veto window). This also covers an *expired* authorization,
        // since `enforce` fails closed without clearing it, so a stale auth must be cancelled (via
        // {cancelAuthorization}) before the same call can be re-authorized.
        bytes32 authId = _authId(poolId, data);
        require(authorizedAfter[authId] == 0, AlreadyAuthorized());

        uint48 validAfter = uint48(block.timestamp) + delaySeconds;
        authorizedAfter[authId] = validAfter;
        emit Authorized(poolId, msg.sender, authId, validAfter);
    }

    /// @inheritdoc IManifest
    function cancelAuthorization(PoolId poolId, bytes calldata data) external {
        require(hubRegistry.manager(poolId, msg.sender), NotManager());

        bytes32 authId = _authId(poolId, data);
        delete authorizedAfter[authId];
        emit AuthorizationCanceled(poolId, authId);
    }

    /// @dev Identifier for a pre-authorized call (exact-calldata match). `poolId` is mixed in even
    ///      though `data` already encodes it, binding the authorization to its pool: without it a
    ///      manager of one pool could authorize a call for another pool sharing the manifest.
    function _authId(PoolId poolId, bytes calldata data) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(poolId.raw(), data));
    }

    //----------------------------------------------------------------------------------------------
    // Classification (pure view)
    //----------------------------------------------------------------------------------------------

    /// @dev Classify the call: 0 if in policy, else the delay an authorization must age; reverts to
    ///      block outright. Deny-by-default, so an unlisted selector is out of policy, not unguarded.
    function _classify(PoolId poolId, address caller, bytes4 selector, bytes calldata payload)
        internal
        view
        returns (uint48)
    {
        // Per-caller confinement: an allowlisted caller may invoke only its listed selectors for this
        // pool; anything else is blocked outright (can't even be authorized). This bounds a narrow
        // keeper/bot even if its key leaks: it can never reach a selector outside its set, whatever
        // else it is a manager for. It only restricts: a permitted selector still flows through the
        // value guards below, which bound how far each call may move things. Unrestricted callers are
        // unaffected.
        if (restricted[poolId][caller]) {
            require(allowed[poolId][caller][selector], CallerNotAllowed());
        }

        // On-chain accounting: accounting selectors come only from the NAVManager and price only from
        // the SimplePriceManager (both run synchronously); any other caller is blocked outright.
        // This binds the Hub-side entry points to the NAVManager address; for a full guarantee the
        // NAVManager's own admin (setNAVHook / updateManager) must also be brought under the manifest
        // in a follow-up, so its manager set can't be changed without a veto.
        if (onchainAccounting) {
            if (_isAccountingSelector(selector)) {
                require(caller == navManager, OnchainAccountingOnly());
                return 0;
            }
            if (selector == IHub.updateSharePrice.selector) {
                require(caller == simplePriceManager, OnchainAccountingOnly());
                return 0;
            }
            // The snapshot hook drives the accounting, so it may only point at the NAVManager.
            if (selector == IHub.setSnapshotHook.selector) {
                (, address hook) = abi.decode(payload, (PoolId, address));
                require(hook == navManager, OnchainAccountingOnly());
                return 0;
            }
        }

        // Out of policy, flat `delay`: hub-manager grant/revoke (delaying revocation stops instant
        // Supervisor removal), request-manager / hook / vault changes, and adding a share class.
        // forgefmt: disable-next-item
        if (selector == IHub.updateHubManager.selector ||
            selector == IHub.setRequestManager.selector ||
            selector == IHub.updateShareHook.selector ||
            selector == IHub.updateVault.selector ||
            selector == IHub.addShareClass.selector
        ) return delay;

        // Out of policy only when the call weakens policy (classified by value).
        if (selector == IHub.updateBalanceSheetManager.selector) return _checkManagerGrant(payload);
        if (selector == IHub.updateAdaptersManager.selector) return _checkManagerGrant(payload);
        if (selector == IHub.updateSharePrice.selector) return _checkSharePrice(poolId, payload);
        if (selector == IHub.updateContract.selector) return _checkUpdateContract(payload);
        if (selector == IHub.setAdapters.selector) return _checkSetAdapters(payload);

        // Replacing the manifest disables all future policy, so it uses the longer `escalation`.
        if (selector == IHub.setManifest.selector) return escalation;

        // In policy: cross-chain notifications (keeper-driven pushes of committed state) and metadata.
        // Everything else (accounting, holdings, config) falls through to the timelocked default.
        // forgefmt: disable-next-item
        if (selector == IHub.notifyPool.selector ||
            selector == IHub.notifyShareClass.selector ||
            selector == IHub.notifyShareMetadata.selector ||
            selector == IHub.notifySharePrice.selector ||
            selector == IHub.notifyAssetPrice.selector ||
            selector == IHub.setPoolMetadata.selector ||
            selector == IHub.updateShareClassMetadata.selector
        ) return 0;

        // Deny-by-default: unlisted selectors fail closed (a method added later gets only the standard
        // delay + sentinel veto, never instant). Sentinel runbook: an authorization for an unknown
        // selector is a high-signal alert and should be scrutinised before its delay elapses.
        return delay;
    }

    /// @dev Accounting surface owned by the NAVManager under `onchainAccounting`. Share price
    ///      (`updateSharePrice`) is the SimplePriceManager's, handled separately.
    function _isAccountingSelector(bytes4 selector) internal pure returns (bool) {
        // forgefmt: disable-next-item
        return selector == IHub.createAccount.selector
            || selector == IHub.setAccountMetadata.selector
            || selector == IHub.updateJournal.selector
            || selector == IHub.initializeHolding.selector
            || selector == IHub.initializeLiability.selector
            || selector == IHub.updateHoldingValue.selector
            || selector == IHub.updateHoldingValuation.selector
            || selector == IHub.updateHoldingIsLiability.selector
            || selector == IHub.setHoldingAccountId.selector;
    }

    /// @dev Balance-sheet / adapters manager updates (same layout): granting needs authorization,
    ///      revoking is in policy.
    function _checkManagerGrant(bytes calldata payload) internal view returns (uint48) {
        (,,, bool canManage,) = abi.decode(payload, (PoolId, uint16, bytes32, bool, address));
        return canManage ? delay : 0;
    }

    /// @dev Contract updates are out of policy (config flows through here to trusted targets), except
    ///      an OnOffRamp withdrawal: it targets an already-configured offramp, so it stays in policy.
    function _checkUpdateContract(bytes calldata payload) internal view returns (uint48) {
        (,,,, bytes memory innerPayload,,) =
            abi.decode(payload, (PoolId, ShareClassId, uint16, bytes32, bytes, uint128, address));
        // Read the first word directly rather than `abi.decode(_, (uint8))`: enforce classifies every
        // updateContract, and decoding as uint8 reverts whenever the first inner word exceeds 255 (any
        // target whose payload starts with a uint256/address/bytes32), which would brick legitimate
        // calls. A word that isn't exactly the Withdraw tag simply falls through to the delay below.
        if (innerPayload.length >= 32 && innerPayload.toUint256(0) == uint256(uint8(IOnOffRamp.TrustedCall.Withdraw))) {
            return 0;
        }
        return delay;
    }

    /// @dev Every local adapter must be a global adapter (poolId=0); a foreign one is blocked outright.
    ///      A valid subset is out of policy, since a weaker subset/threshold needs a veto window.
    function _checkSetAdapters(bytes calldata payload) internal view returns (uint48) {
        (, uint16 centrifugeId, IAdapter[] memory localAdapters,,,,) =
            abi.decode(payload, (PoolId, uint16, IAdapter[], bytes32[], uint8, uint8, address));

        PoolId globalPool = PoolId.wrap(0);
        uint16 sessionId = multiAdapter.activeSessionId(centrifugeId, globalPool);
        uint8 quorum = multiAdapter.quorum(centrifugeId, globalPool);

        // Read the global set once instead of re-fetching each slot for every local adapter.
        IAdapter[] memory globalAdapters = new IAdapter[](quorum);
        for (uint256 j; j < quorum; j++) {
            globalAdapters[j] = multiAdapter.adapters(centrifugeId, globalPool, sessionId, j);
        }

        for (uint256 i; i < localAdapters.length; i++) {
            bool isGlobal;
            for (uint256 j; j < quorum; j++) {
                if (localAdapters[i] == globalAdapters[j]) {
                    isGlobal = true;
                    break;
                }
            }
            require(isGlobal, AdapterMismatch());
        }

        return delay;
    }

    /// @dev Out of policy if the single move exceeds `maxPriceDelta` or the move/second since the last
    ///      executed update exceeds `thresholdPerSecond` (same-block updates are forced out of policy
    ///      to stop chunking). First update per share class is unguarded; `computedAt` is ignored.
    function _checkSharePrice(PoolId poolId, bytes calldata payload) internal view returns (uint48) {
        if (thresholdPerSecond == 0 && maxPriceDelta == 0) return 0;

        (, ShareClassId scId, D18 newPrice,) = abi.decode(payload, (PoolId, ShareClassId, D18, uint64));

        uint64 lastUpdate = lastPriceUpdate[poolId][scId];
        if (lastUpdate == 0) return 0; // no executed baseline yet, first update is in policy

        // Zero elapsed (same block) can't be rate-bounded, so out of policy: stops chunking many
        // sub-threshold updates into one tx/block.
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) return delay;

        (D18 lastPrice,) = shareClassManager.pricePoolPerShare(poolId, scId);
        uint128 newRaw = D18.unwrap(newPrice);
        uint128 lastRaw = D18.unwrap(lastPrice);
        uint256 priceDelta = newRaw > lastRaw ? newRaw - lastRaw : lastRaw - newRaw;

        if (maxPriceDelta != 0 && priceDelta >= maxPriceDelta) return delay;
        if (thresholdPerSecond != 0 && priceDelta / elapsed >= thresholdPerSecond) return delay;

        return 0;
    }
}
