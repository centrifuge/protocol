// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStdManifest, IStdManifestFactory} from "./interfaces/IStdManifest.sol";

import {D18} from "../misc/types/D18.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {AssetId} from "../core/types/AssetId.sol";
import {IHub} from "../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IManifest} from "../core/hub/interfaces/IManifest.sol";
import {IAdapter} from "../core/messaging/interfaces/IAdapter.sol";
import {IHubRegistry} from "../core/hub/interfaces/IHubRegistry.sol";
import {IMultiAdapter} from "../core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../core/hub/interfaces/IShareClassManager.sol";

import {ManagerAction} from "../vaults/interfaces/IBatchRequestManager.sol";

/// @title  Standard Manifest
/// @notice Default pool policy installed on the Hub via {IHub.setManifest}. This contract is a pure
///         classifier; the authorization ledger (storing/maturing/vetoing/consuming authorizations and
///         emitting their events) lives in {HubRegistry}, shared by every manifest.
///
///         The Hub calls {enforce} on every guarded manager method. In-policy calls (delay 0) run
///         synchronously; out-of-policy calls must be pre-authorized via {IHubRegistry.authorize} and
///         matured past the delay, leaving sentinels a veto window via {IHubRegistry.cancelAuthorization}.
///         {enforce} consumes the matured authorization from the registry. A matured authorization is
///         executable only within `expiry` (then it fails closed), so it can neither be banked while
///         cheap nor held until the baseline has drifted. One instance can serve many pools.
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
    using CastLib for bytes32;

    // Dependencies
    IHub public immutable hub;
    address public immutable navManager;
    address public immutable requestManager;
    address public immutable contractUpdaterForwarder;
    IHubRegistry public immutable hubRegistry;
    IMultiAdapter public immutable multiAdapter;
    address public immutable simplePriceManager;
    IShareClassManager public immutable shareClassManager;

    // Policy. Price guards differ in unit and disable sentinel; see {IStdManifest.Config}.
    uint48 public immutable delay;
    uint48 public immutable expiry;
    uint48 public immutable escalation;
    bool public immutable onchainAccounting;
    uint128 public immutable thresholdPerSecond;
    uint128 public immutable maxBrmPriceDeviation;
    uint128 public immutable maxAbsolutePriceDelta;

    // State
    mapping(PoolId => mapping(ShareClassId => uint64)) public lastPriceUpdate;
    mapping(PoolId poolId => mapping(address caller => bool)) public restricted;
    mapping(PoolId poolId => mapping(address caller => mapping(bytes4 selector => bool))) public allowed;

    constructor(IHub hub_, IMultiAdapter multiAdapter_, IShareClassManager shareClassManager_, Config memory config) {
        // Dependencies
        hub = hub_;
        navManager = config.navManager;
        requestManager = config.requestManager;
        contractUpdaterForwarder = config.contractUpdaterForwarder;
        hubRegistry = hub_.hubRegistry();
        multiAdapter = multiAdapter_;
        simplePriceManager = config.simplePriceManager;
        shareClassManager = shareClassManager_;

        // Policy
        delay = config.delay;
        expiry = config.expiry;
        escalation = config.escalation;
        onchainAccounting = config.onchainAccounting;
        thresholdPerSecond = config.thresholdPerSecond;
        maxBrmPriceDeviation = config.maxBrmPriceDeviation;
        maxAbsolutePriceDelta = config.maxAbsolutePriceDelta;

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
    /// @dev The authorization ledger (storing/maturing/consuming) lives in {HubRegistry}; this only
    ///      classifies and, when out of policy, consumes a matured authorization there.
    function enforce(PoolId poolId, address caller, bytes calldata data) external {
        require(msg.sender == address(hub), NotHub());
        (bytes4 selector, bytes calldata payload) = data.decodeCall();

        if (_classify(poolId, caller, selector, payload) != 0) {
            hubRegistry.consumeAuthorization(poolId, caller, data, expiry);
        }

        // Anchor the share-price baseline to this executed update (never from authorize/cancel), so
        // the rate guard measures from actual price changes.
        if (selector == IHub.updateSharePrice.selector) {
            (, ShareClassId scId,,) = abi.decode(payload, (PoolId, ShareClassId, D18, uint64));
            lastPriceUpdate[poolId][scId] = uint64(block.timestamp);
        }
    }

    /// @inheritdoc IManifest
    /// @dev Called by {HubRegistry.authorize} (to price the delay) and by {enforce}. Reverts to block
    ///      a forbidden call outright.
    function classify(PoolId poolId, address caller, bytes calldata data) external view returns (uint48) {
        (bytes4 selector, bytes calldata payload) = data.decodeCall();
        return _classify(poolId, caller, selector, payload);
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

        // Out of policy only when the call weakens policy (classified by value): a manager grant,
        // a share-price move beyond the rate/cap guard, a non-withdrawal contract update, a weaker
        // adapter set, or a BRM managerCall whose price deviates beyond `maxBrmPriceDeviation`.
        if (selector == IHub.updateManager.selector) return _checkManagerGrant(payload);
        if (selector == IHub.updateSharePrice.selector) return _checkSharePrice(poolId, payload);
        if (selector == IHub.setAdapters.selector) return _checkSetAdapters(payload);
        if (selector == IHub.managerCall.selector) return _checkManagerCall(poolId, payload);

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

    /// @dev BalanceSheet / Adapter / Gateway / Spoke manager updates (same layout): granting needs
    ///      authorization, revoking is in policy.
    function _checkManagerGrant(bytes calldata payload) internal view returns (uint48) {
        (,,,, bool canManage,) = abi.decode(payload, (PoolId, uint16, uint8, bytes32, bool, address));
        return canManage ? delay : 0;
    }

    /// @dev `managerCall` classification, pinned by target. A call to the `contractUpdaterForwarder` is a
    ///      wrapped contract update (the forwarder unwraps `(scId, realTarget, inner)` and forwards to
    ///      `ContractUpdater.trustedCall`), so it is classified like a legacy contract update (see
    ///      {_classifyContractUpdate}). A call to the configured BRM is in policy (routine keeper ops) but
    ///      additionally bounded by {_checkRequestPrice}. Every other target falls to `delay` (timelocked +
    ///      vetoable). Pinning the targets prevents ABI collisions where another target's payload shares a
    ///      classified action's leading byte; neither binding can be repointed instantly (`setRequestManager`
    ///      is out of policy, and both pins are immutable CREATE3 anchors).
    function _checkManagerCall(PoolId poolId, bytes calldata payload) internal view returns (uint48) {
        (,, bytes32 target, bytes memory inner,,,) =
            abi.decode(payload, (PoolId, uint16, bytes32, bytes, uint128, uint256, address));

        address targetAddr = target.toAddress();
        if (targetAddr == contractUpdaterForwarder) return _classifyContractUpdate(inner);
        if (targetAddr != requestManager) return delay;
        return _checkRequestPrice(poolId, inner);
    }

    /// @dev Classify a wrapped contract update (a managerCall whose target is the `contractUpdaterForwarder`).
    ///      Always out of policy: timelocked + vetoable. There is deliberately NO fast path. A tag-only
    ///      shortcut (the former OnOffRamp `Withdraw` exception) keyed on the inner payload's leading word and
    ///      ignored the target, so any `trustedCall` target accepting that leading word (SlippageGuard,
    ///      QueueManager, …) inherited the shortcut and bypassed the timelock (Sherlock #15). A *target-
    ///      validated* fast path (verifying the target is the legitimate offramp for the payload's scId) could
    ///      be reintroduced here, but a tag-only one must not.
    function _classifyContractUpdate(bytes memory) internal view returns (uint48) {
        return delay;
    }

    /// @dev Bound the BRM-supplied price against the pool's committed main price: issue/revoke compare
    ///      `pricePoolPerShare`, approve deposits/redeems compare `pricePoolPerAsset`. Force-cancels and
    ///      unknown shapes carry no price and stay in policy. A reverting reference bubbles up by design
    ///      (never approve against a broken oracle). A zero reference fails closed: a manager must not
    ///      approve or issue/revoke shares without a committed hub price.
    function _checkRequestPrice(PoolId poolId, bytes memory inner) internal view returns (uint48) {
        if (maxBrmPriceDeviation == type(uint128).max) return 0; // guard disabled
        if (inner.length < 32) return delay; // malformed: fail closed

        uint8 kind = uint8(inner.toUint256(0));

        D18 brmPrice;
        D18 mainPrice;
        if (kind == uint8(ManagerAction.IssueShares) || kind == uint8(ManagerAction.RevokeShares)) {
            if (inner.length < 160) return delay; // need the scId + price words
            ShareClassId scId = ShareClassId.wrap(inner.toBytes16(32));
            brmPrice = D18.wrap(inner.toUint128(144));
            (mainPrice,) = shareClassManager.pricePoolPerShare(poolId, scId);
        } else if (kind == uint8(ManagerAction.ApproveDeposits) || kind == uint8(ManagerAction.ApproveRedeems)) {
            if (inner.length < 192) return delay; // need the scId + assetId + price words
            ShareClassId scId = ShareClassId.wrap(inner.toBytes16(32));
            AssetId assetId = AssetId.wrap(inner.toUint128(80));
            brmPrice = D18.wrap(inner.toUint128(176));
            mainPrice = hub.pricePoolPerAsset(poolId, scId, assetId); // direct call: a revert bubbles up
        } else {
            return 0; // force-cancels / unknown shapes carry no price
        }

        if (mainPrice.isZero()) return delay; // no committed reference: fail closed
        return brmPrice.withinDeviation(mainPrice, maxBrmPriceDeviation) ? 0 : delay;
    }

    /// @dev Every local adapter must be a global adapter (poolId=0); a foreign one is blocked outright.
    ///      A valid subset is out of policy, since a weaker subset/threshold needs a veto window.
    function _checkSetAdapters(bytes calldata payload) internal view returns (uint48) {
        (, uint16 centrifugeId, IAdapter[] memory localAdapters,,,) =
            abi.decode(payload, (PoolId, uint16, IAdapter[], bytes32[], uint8, address));

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

    /// @dev Out of policy if the single move exceeds `maxAbsolutePriceDelta` or the move/second since the
    ///      last executed update exceeds `thresholdPerSecond` (same-block updates are forced out of policy
    ///      to stop chunking). First update per share class is unguarded; `computedAt` is ignored.
    function _checkSharePrice(PoolId poolId, bytes calldata payload) internal view returns (uint48) {
        if (thresholdPerSecond == 0 && maxAbsolutePriceDelta == 0) return 0;

        (, ShareClassId scId, D18 newPrice,) = abi.decode(payload, (PoolId, ShareClassId, D18, uint64));

        uint64 lastUpdate = lastPriceUpdate[poolId][scId];
        if (lastUpdate == 0) return 0; // no executed baseline yet, first update is in policy

        // Zero elapsed (same block) can't be rate-bounded, so out of policy: stops chunking many
        // sub-threshold updates into one tx/block.
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) return delay;

        (D18 lastPrice,) = shareClassManager.pricePoolPerShare(poolId, scId);
        uint256 priceDelta = MathLib.absDiff(D18.unwrap(newPrice), D18.unwrap(lastPrice));

        if (maxAbsolutePriceDelta != 0 && priceDelta >= maxAbsolutePriceDelta) return delay;
        if (thresholdPerSecond != 0 && priceDelta / elapsed >= thresholdPerSecond) return delay;

        return 0;
    }
}

/// @title  Standard Manifest Factory
/// @notice Deploys StdManifest instances which are not necessarily pool-scoped.
contract StdManifestFactory is IStdManifestFactory {
    IHub public immutable hub;
    IMultiAdapter public immutable multiAdapter;
    IShareClassManager public immutable shareClassManager;

    constructor(IHub hub_, IMultiAdapter multiAdapter_, IShareClassManager shareClassManager_) {
        hub = hub_;
        multiAdapter = multiAdapter_;
        shareClassManager = shareClassManager_;
    }

    /// @inheritdoc IStdManifestFactory
    function newStdManifest(IStdManifest.Config memory config) external returns (IStdManifest) {
        StdManifest manifest = new StdManifest{salt: _salt(config)}(hub, multiAdapter, shareClassManager, config);

        emit DeployStdManifest(address(manifest));
        return IStdManifest(address(manifest));
    }

    /// @inheritdoc IStdManifestFactory
    function previewStdManifest(IStdManifest.Config memory config) external view returns (address) {
        bytes32 hash = keccak256(
            abi.encodePacked(
                bytes1(0xff),
                address(this),
                _salt(config),
                keccak256(
                    abi.encodePacked(
                        type(StdManifest).creationCode, abi.encode(hub, multiAdapter, shareClassManager, config)
                    )
                )
            )
        );
        return address(uint160(uint256(hash)));
    }

    function _salt(IStdManifest.Config memory config) internal view returns (bytes32) {
        return keccak256(abi.encode(hub, multiAdapter, shareClassManager, config));
    }
}
