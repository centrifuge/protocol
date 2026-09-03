// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IStdHubPolicy, IStdHubPolicyFactory} from "./interfaces/IStdHubPolicy.sol";

import {D18} from "../../misc/types/D18.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {MathLib} from "../../misc/libraries/MathLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {AssetId} from "../../core/types/AssetId.sol";
import {IHub} from "../../core/hub/interfaces/IHub.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IHubRegistry} from "../../core/hub/interfaces/IHubRegistry.sol";
import {IPolicy, IHubPolicy} from "../../core/utils/interfaces/IPolicy.sol";
import {IMultiAdapter} from "../../core/messaging/interfaces/IMultiAdapter.sol";
import {IShareClassManager} from "../../core/hub/interfaces/IShareClassManager.sol";

import {IBridgeCircuitBreaker} from "../../hooks/bridge/interfaces/IBridgeCircuitBreaker.sol";
import {UpdateRestrictionType} from "../../token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {ManagerAction} from "../../vaults/interfaces/IBatchRequestManager.sol";

/// @title  Standard Hub Policy
/// @notice Default pool policy installed on the Hub via {IHub.setPolicy}. A pure classifier; the
///         authorization ledger lives in {HubRegistry}, shared by every policy.
///
///         The Hub calls {enforce} on every guarded manager method. In-policy calls (delay 0) run
///         synchronously; out-of-policy calls must be pre-authorized via {IHubRegistry.initiateAuthorization}, mature
///         past `delay`, and are consumed by {enforce} within `expiry` (else they fail closed). Sentinels
///         get a veto window via {Supervisor.cancelAuthorization}. One instance can serve many pools.
///         `escalation` (a longer delay) applies only to replacing the policy; a construction-time
///         allowlist can additionally confine a caller to a fixed selector set.
///
///         Per-selector policy (see {_authorizationDelay} for the exhaustive dispatch):
///         - Accounting/price writes, when `onchainAccounting` is set, are gated to the NAVManager /
///           SimplePriceManager and run instantly; `updateSharePrice` is further rate/cap-bounded by
///           {_checkSharePrice}.
///         - `updateHubManager`, `setRequestManager`, `updateVault`, `updateCurrency`, `addShareClass`,
///           `notifyShareClass`, `updateManager`, `setAdapters`, and `authorizeSpokeCall` are always out of policy.
///         - `managerCall` is out of policy, additionally bounded by {_checkManagerCall}, which pins the
///           call by target: the configured request manager (BRM) is bounded by {_checkRequestPrice}, a
///           SetPaused to the configured bridging hook is instant, every other target is out of policy.
///         - `setPolicy` and `setSpokePolicy` use `escalation` instead of `delay`.
///         - Cross-chain notifications and pool/share metadata updates are in policy, except
///           `notifyShareClass`, which carries a caller-supplied registrar rather than committed state.
///         - Everything else (deny-by-default) falls through to `delay`.
contract StdHubPolicy is IStdHubPolicy {
    using BytesLib for bytes;
    using CastLib for bytes32;

    /// @dev Selectors for the two updateSharePrice overloads. Explicit constants are required because
    ///      Solidity cannot disambiguate IHub.updateSharePrice.selector once the name is overloaded.
    bytes4 private constant UPDATE_SHARE_PRICE_WITH_TIMESTAMP =
        bytes4(keccak256("updateSharePrice(uint64,bytes16,uint128,uint64)"));
    bytes4 private constant UPDATE_SHARE_PRICE = bytes4(keccak256("updateSharePrice(uint64,bytes16,uint128)"));

    // Dependencies
    IHub public immutable hub;
    address public immutable navManager;
    address public immutable bridgingHook;
    address public immutable requestManager;
    address public immutable oracleValuation;
    IHubRegistry public immutable hubRegistry;
    IMultiAdapter public immutable multiAdapter;
    address public immutable simplePriceManager;
    IShareClassManager public immutable shareClassManager;

    // Parameters
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
        require(config.delay > 0 && config.escalation > config.delay && config.expiry > 0, InvalidConfig());

        // Dependencies
        hub = hub_;
        navManager = config.navManager;
        requestManager = config.requestManager;
        bridgingHook = config.bridgingHook;
        oracleValuation = config.oracleValuation;
        hubRegistry = hub_.hubRegistry();
        multiAdapter = multiAdapter_;
        simplePriceManager = config.simplePriceManager;
        shareClassManager = shareClassManager_;

        // Parameters
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

    /// @inheritdoc IPolicy
    /// @dev The authorization ledger (storing/maturing/consuming) lives in {HubRegistry}; this only
    ///      classifies and, when out of policy, consumes a matured authorization there.
    function enforce(PoolId poolId, address caller, bytes calldata data) external {
        require(msg.sender == address(hub), NotEnforcer());
        (bytes4 selector, bytes calldata payload) = data.decodeCall();

        // In onchainAccounting mode, share-price updates may only be executed by the SimplePriceManager.
        // The check lives here (not in _authorizationDelay) so pool managers can still pre-authorize out-of-policy
        // price moves via hubRegistry.initiateAuthorization, which calls authorizationDelay with the manager as caller.
        if (onchainAccounting && (_isSharePriceUpdate(selector))) {
            require(caller == simplePriceManager, OnchainAccountingOnly());
        }

        if (_authorizationDelay(poolId, caller, selector, payload) != 0) {
            hubRegistry.consumeAuthorization(poolId, caller, data, expiry);
        }

        // Anchor the share-price baseline to this executed update (never from authorize/cancel), so the
        // rate guard measures from actual price changes. Re-committing the committed price is not a move:
        // leaving the baseline alone stops no-op recomputes from tightening the guard. The very first
        // executed update always anchors, even when it re-commits the stored price, so the unguarded first
        // update can't be spent on a no-op (a fresh share class reads back 0) and leave the guard unarmed.
        // On a policy change someone can permissionlessly commit the current price (NAVManager.updateHoldingValue
        // is open), anchoring the baseline at that block and narrowing the accepted deviation for the next move.
        if (_isSharePriceUpdate(selector)) {
            (, ShareClassId scId, D18 newPrice) = abi.decode(payload[:96], (PoolId, ShareClassId, D18));
            (D18 lastPrice,) = shareClassManager.pricePoolPerShare(poolId, scId);
            if (newPrice.raw() != lastPrice.raw() || lastPriceUpdate[poolId][scId] == 0) {
                lastPriceUpdate[poolId][scId] = uint64(block.timestamp);
            }
        }
    }

    /// @inheritdoc IHubPolicy
    /// @dev Called by {HubRegistry.initiateAuthorization} (to price the delay) and by {enforce}. Reverts to block
    ///      a forbidden call outright.
    function authorizationDelay(PoolId poolId, address caller, bytes calldata data) external view returns (uint48) {
        (bytes4 selector, bytes calldata payload) = data.decodeCall();
        return _authorizationDelay(poolId, caller, selector, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Classification (pure view)
    //----------------------------------------------------------------------------------------------

    /// @dev Classify the call: 0 if in policy, else the delay an authorization must age; reverts to
    ///      block outright. Deny-by-default, so an unlisted selector is out of policy, not unguarded.
    function _authorizationDelay(PoolId poolId, address caller, bytes4 selector, bytes calldata payload)
        internal
        view
        returns (uint48)
    {
        // Per-caller confinement: an allowlisted caller may invoke only its listed selectors for this pool;
        // anything else is blocked outright. A permitted selector still flows through the value guards below.
        if (restricted[poolId][caller]) {
            require(allowed[poolId][caller][selector], CallerNotAllowed());
        }

        // Oracle valuation is in policy for updateHoldingValue with or without onchain accounting.
        if (oracleValuation != address(0) && caller == oracleValuation && selector == IHub.updateHoldingValue.selector)
        {
            return 0;
        }

        // On-chain accounting: accounting selectors come only from the NAVManager, price only from the
        // SimplePriceManager (both run synchronously); any other caller is blocked outright.
        if (onchainAccounting) {
            if (_isAccountingSelector(selector)) {
                require(caller == navManager, OnchainAccountingOnly());
                return 0;
            }
            if (_isSharePriceUpdate(selector)) {
                return _checkSharePrice(poolId, payload);
            }
            // The snapshot hook drives the accounting, so it may only point at the NAVManager.
            if (selector == IHub.setSnapshotHook.selector) {
                (, address hook) = abi.decode(payload, (PoolId, address));
                require(hook == navManager, OnchainAccountingOnly());
                return 0;
            }
        }

        // Out of policy, flat `delay`: hub-manager grant/revoke (delaying revocation stops instant
        // Supervisor removal), request-manager / hook / vault / currency changes, adding a share class, and
        // notifying it to a spoke, whose caller-supplied registrar becomes the share token's mint authority.
        // Sentinel runbook: check that registrar against the canonical one for the destination chain.
        // forgefmt: disable-next-item
        if (selector == IHub.updateHubManager.selector ||
            selector == IHub.setRequestManager.selector ||
            selector == IHub.updateVault.selector ||
            selector == IHub.updateCurrency.selector ||
            selector == IHub.addShareClass.selector ||
            selector == IHub.notifyShareClass.selector ||
            selector == IHub.setAdapters.selector ||
            selector == IHub.authorizeSpokeCall.selector
        ) return delay;

        // Out of policy: a manager grant or revoke (instant mass-revocation by one manager could strip
        // all others), a share-price move beyond the rate/cap guard, a non-withdrawal contract update,
        // or a BRM managerCall whose price deviates beyond `maxBrmPriceDeviation`.
        if (selector == IHub.updateManager.selector) return delay;
        if (_isSharePriceUpdate(selector)) {
            return _checkSharePrice(poolId, payload);
        }
        if (selector == IHub.updateRestriction.selector) return _checkRestriction(payload);
        if (selector == IHub.managerCall.selector) return _checkManagerCall(poolId, payload);

        // The sentinel veto path runs instantly, but still passes through the per-caller confinement
        // above, so a restricted manager can't wield it as a pool-wide governance-DoS primitive.
        if (selector == IHub.cancelAuthorization.selector) return 0;

        // Replacing a policy (the local hub one, or a spoke's pushed one) disables all future policy on
        // that side, so it uses the longer `escalation`.
        if (selector == IHub.setPolicy.selector || selector == IHub.setSpokePolicy.selector) return escalation;

        // In policy: cross-chain notifications (keeper-driven pushes of committed state) and metadata.
        // `notifyShareClass` is excluded above: it is a one-shot deployment carrying an uncommitted registrar,
        // not a re-push. Everything else (accounting, holdings, config) falls through to the timelocked default.
        // forgefmt: disable-next-item
        if (selector == IHub.notifyPool.selector ||
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

    function _isSharePriceUpdate(bytes4 selector) private pure returns (bool) {
        return selector == UPDATE_SHARE_PRICE_WITH_TIMESTAMP || selector == UPDATE_SHARE_PRICE;
    }

    /// @dev Accounting surface owned by the NAVManager under `onchainAccounting`. Share price
    ///      (`updateSharePrice`) is the SimplePriceManager's, handled separately.
    function _isAccountingSelector(bytes4 selector) internal pure returns (bool) {
        // forgefmt: disable-next-item
        return selector == IHub.createAccount.selector
            || selector == IHub.setAccountMetadata.selector
            || selector == IHub.updateJournal.selector
            || selector == IHub.initializeHolding.selector
            || selector == IHub.updateHoldingValue.selector
            || selector == IHub.updateHoldingValuation.selector;
    }

    /// @dev A canonical `Freeze` is strictly tightening, so it runs instantly: waiting out `delay` would let
    ///      the target bridge/redeem/transfer out of reach, and a scheduled authorization would leak the
    ///      target and maturity publicly. Everything else (Unfreeze, Member, malformed) stays on `delay`.
    function _checkRestriction(bytes calldata payload) internal view returns (uint48) {
        // Only `update` is needed; the trailing (extraGasLimit, refund) is skipped via the dynamic offset.
        (,,, bytes memory update) = abi.decode(payload, (PoolId, ShareClassId, uint16, bytes));
        // Canonical Freeze is exactly `abi.encodePacked(Freeze, user)` (1-byte type + 32-byte user). Comparing
        // the raw byte (not casting to the enum) keeps an out-of-range type failing closed instead of reverting.
        if (update.length != 33) return delay;
        if (update.toUint8(0) != uint8(UpdateRestrictionType.Freeze)) return delay;
        return 0;
    }

    /// @dev `managerCall` classification, pinned by target: the BRM is in policy but bounded by
    ///      {_checkRequestPrice}, a SetPaused to the bridging hook is in policy, everything else is
    ///      `delay`. Target pins are local addresses, so a remote `centrifugeId` always falls through to
    ///      `delay`.
    function _checkManagerCall(PoolId poolId, bytes calldata payload) internal view returns (uint48) {
        // Below 224 bytes (7 x 32, the managerCall tuple's minimum ABI encoding), abi.decode would revert;
        // classify as out-of-policy instead. {Supervisor._checkNotSelfRemoval} shares this shape and
        // threshold; if the managerCall tuple changes, update both together.
        if (payload.length < 224) return delay;
        (, uint16 centrifugeId, bytes32 target, bytes memory inner,,,) =
            abi.decode(payload, (PoolId, uint16, bytes32, bytes, uint128, uint256, address));
        if (centrifugeId != hub.sender().localCentrifugeId()) return delay;

        address targetAddr = target.toAddress();
        if (targetAddr == requestManager) return _checkRequestPrice(poolId, inner);
        if (
            bridgingHook != address(0) && targetAddr == bridgingHook && inner.length >= 32
                && inner.toUint256(0) == uint256(IBridgeCircuitBreaker.ConfigKind.SetPaused)
        ) return 0;
        return delay;
    }

    /// @dev Bounds the BRM-supplied price against the pool's committed price (share price for issue/revoke,
    ///      asset price for approvals). Unknown shapes and a reverting/zero reference fail closed to `delay`.
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
        } else if (
            kind == uint8(ManagerAction.ForceCancelDepositRequest)
                || kind == uint8(ManagerAction.ForceCancelRedeemRequest)
        ) {
            return 0; // returns the investor's own pending funds, carries no price
        } else {
            return delay; // unrecognized kind: deny-by-default, don't wave through instantly
        }

        if (mainPrice.isZero()) return delay; // no committed reference: fail closed
        return brmPrice.withinDeviation(mainPrice, maxBrmPriceDeviation) ? 0 : delay;
    }

    /// @dev Out of policy if the single move exceeds `maxAbsolutePriceDelta` or the move/second since the
    ///      last executed update exceeds `thresholdPerSecond` (same-block updates are forced out of policy
    ///      to stop chunking). First update per share class under this policy instance is unguarded, as is
    ///      a re-commit of the committed price (no move to bound); `computedAt` is ignored. {enforce}
    ///      anchors the baseline on that first update either way, so the unguarded slot is spent once and
    ///      not by a no-op.
    function _checkSharePrice(PoolId poolId, bytes calldata payload) internal view returns (uint48) {
        if (thresholdPerSecond == 0 && maxAbsolutePriceDelta == 0) return 0;

        (, ShareClassId scId, D18 newPrice) = abi.decode(payload[:96], (PoolId, ShareClassId, D18));

        uint64 lastUpdate = lastPriceUpdate[poolId][scId];
        if (lastUpdate == 0) return 0; // no executed baseline yet, first update is in policy

        (D18 lastPrice,) = shareClassManager.pricePoolPerShare(poolId, scId);
        uint256 priceDelta = MathLib.absDiff(D18.unwrap(newPrice), D18.unwrap(lastPrice));
        if (priceDelta == 0) return 0;

        // Zero elapsed (same block) can't be rate-bounded, so out of policy: stops chunking many
        // sub-threshold updates into one tx/block.
        uint256 elapsed = block.timestamp - lastUpdate;
        if (elapsed == 0) return delay;

        if (maxAbsolutePriceDelta != 0 && priceDelta >= maxAbsolutePriceDelta) return delay;
        if (thresholdPerSecond != 0 && priceDelta / elapsed >= thresholdPerSecond) return delay;

        return 0;
    }
}

/// @title  Standard Policy Factory
/// @notice Deploys StdHubPolicy instances which are not necessarily pool-scoped.
contract StdHubPolicyFactory is IStdHubPolicyFactory {
    IHub public immutable hub;
    IMultiAdapter public immutable multiAdapter;
    IShareClassManager public immutable shareClassManager;

    constructor(IHub hub_, IMultiAdapter multiAdapter_, IShareClassManager shareClassManager_) {
        hub = hub_;
        multiAdapter = multiAdapter_;
        shareClassManager = shareClassManager_;
    }

    /// @inheritdoc IStdHubPolicyFactory
    function newHubPolicy(IStdHubPolicy.Config memory config) external returns (IStdHubPolicy) {
        StdHubPolicy policy = new StdHubPolicy{salt: _salt(config)}(hub, multiAdapter, shareClassManager, config);

        emit DeployHubPolicy(address(policy));
        return IStdHubPolicy(address(policy));
    }

    /// @inheritdoc IStdHubPolicyFactory
    function previewHubPolicy(IStdHubPolicy.Config memory config) external view returns (address) {
        bytes32 hash = keccak256(abi.encodePacked(bytes1(0xff), address(this), _salt(config), _initCodeHash(config)));
        return address(uint160(uint256(hash)));
    }

    function _salt(IStdHubPolicy.Config memory config) internal view returns (bytes32) {
        return keccak256(abi.encode(hub, multiAdapter, shareClassManager, config));
    }

    function _initCodeHash(IStdHubPolicy.Config memory config) internal view returns (bytes32) {
        return keccak256(
            abi.encodePacked(type(StdHubPolicy).creationCode, abi.encode(hub, multiAdapter, shareClassManager, config))
        );
    }
}
