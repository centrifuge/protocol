// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "../../../../src/misc/types/D18.sol";
import {CastLib} from "../../../../src/misc/libraries/CastLib.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {AccountId} from "../../../../src/core/types/AccountId.sol";
import {JournalEntry} from "../../../../src/core/hub/interfaces/IAccounting.sol";
import {IHubRegistry} from "../../../../src/core/hub/interfaces/IHubRegistry.sol";
import {ISnapshotHook} from "../../../../src/core/hub/interfaces/ISnapshotHook.sol";

import {
    UpdateRestrictionType,
    UpdateRestrictionMessageLib
} from "../../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {vm} from "@chimera/Hevm.sol";
import {OpType} from "../BeforeAfter.sol";
import {Properties} from "../properties/Properties.sol";
import {BaseTargetFunctions} from "@chimera/BaseTargetFunctions.sol";
import {IStdHubPolicy} from "../../../../src/policies/hub/interfaces/IStdHubPolicy.sol";

/// @notice Pool P's manager calls under the strict policy. Each handler says what the policy must answer from the
///         call alone, apart from the contract (in policy, held for an authorization, or blocked outright), then
///         sends the call with or without a matured authorization and holds the hub to that answer.
abstract contract StrictPolicyTargets is BaseTargetFunctions, Properties {
    using CastLib for *;
    using UpdateRestrictionMessageLib for *;

    /// @dev Only a canonical freeze is in policy: an unfreeze, a membership and a freeze that is not exactly a type
    ///      byte and a user wait for an authorization, which one call spends.
    function strict_updateRestriction(uint256 kindSeed, uint256 actorSeed, bool authorized)
        public
        updateGhosts(OpType.MANAGER)
    {
        address actor = _actor(actorSeed);
        bytes32 user = actor.toBytes32();
        uint256 kind = kindSeed % 5;
        bytes memory update;
        if (kind == 0) update = UpdateRestrictionMessageLib.UpdateRestrictionFreeze({user: user}).serialize();
        else if (kind == 1) update = UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze({user: user}).serialize();
        else if (kind == 2) update = _memberMsg(actor);
        else if (kind == 3) update = abi.encodePacked(UpdateRestrictionType.Freeze, user, uint8(0));
        else update = abi.encodePacked(UpdateRestrictionType.Freeze);
        bytes memory data = abi.encodeCall(hub.updateRestriction, (poolP, scP, CENTRIFUGE_ID, update, 0, REFUND));

        bool instant = kind == 0;
        bool sent = _sendUnderPolicy(FM, data, instant, authorized, kind <= 2);
        if (sent && !instant) {
            (bool again, bytes memory ret) = _callAs(FM, address(hub), data);
            t(!again && bytes4(ret) == IHubRegistry.Unauthorized.selector, "one authorization let a call through twice");
        }
        sent ? _ok("strict_updateRestriction") : _reverted("strict_updateRestriction");
    }

    /// @dev Under on-chain accounting the manager can neither send nor schedule an accounting call, cannot point the
    ///      snapshot hook anywhere but at the NAV manager, and cannot send a price. The NAV manager's accounting call
    ///      goes through at once.
    function strict_accounting(uint256 seed) public updateGhosts(OpType.MANAGER) {
        uint256 which = seed % 8;
        bytes memory data;
        if (which == 0) {
            data = abi.encodeCall(hub.createAccount, (poolP, AccountId.wrap(seed), true));
        } else if (which == 1) {
            data = abi.encodeCall(hub.setAccountMetadata, (poolP, ASSET_ACCOUNT, abi.encode(seed)));
        } else if (which == 2) {
            JournalEntry[] memory none = new JournalEntry[](0);
            data = abi.encodeCall(hub.updateJournal, (poolP, none, none));
        } else if (which == 3) {
            data = abi.encodeCall(hub.initializeHolding, (poolP, scP, navAssets[0], identityValuation, _accounts()));
        } else if (which == 4) {
            data = abi.encodeCall(hub.updateHoldingValue, (poolP, scP, usdcId));
        } else if (which == 5) {
            data = abi.encodeCall(hub.updateHoldingValuation, (poolP, scP, usdcId, identityValuation));
        } else if (which == 6) {
            data = abi.encodeCall(hub.setSnapshotHook, (poolP, ISnapshotHook(address(priceManager))));
        } else {
            data = _priceCall(d18(uint128(between(seed, 1, 2e18))));
        }

        vm.deal(FM, 1 ether);
        (bool success, bytes memory ret) = _callAs(FM, address(hub), data);
        t(
            !success && bytes4(ret) == IStdHubPolicy.OnchainAccountingOnly.selector,
            "the manager's accounting or price call was not refused under on-chain accounting"
        );
        if (which != 7) {
            (bool scheduled,) =
                address(hubRegistry).call(abi.encodeCall(hubRegistry.initiateAuthorization, (poolP, FM, data)));
            t(!scheduled, "a call blocked outright could be scheduled");
        }

        eq(
            strictPolicy.authorizationDelay(
                poolP, FM, abi.encodeCall(hub.setSnapshotHook, (poolP, ISnapshotHook(address(navManager))))
            ),
            0,
            "pointing the snapshot hook at the NAV manager is not in policy"
        );
        (success,) =
            _callAs(address(navManager), address(hub), abi.encodeCall(hub.updateHoldingValue, (poolP, scP, usdcId)));
        t(success, "the NAV manager's accounting call was held or refused");
        _ok("strict_accounting");
    }

    /// @dev The price manager's update is in policy when it is the first under the policy, re-commits the price, or
    ///      moves it by less than the absolute bound and slower than the rate bound since the last executed move.
    ///      Any other move, one in the block of the last included, waits for an authorization.
    function strict_updateSharePrice(uint256 moveSeed, uint8 mode, bool up, bool authorized)
        public
        updateGhosts(OpType.MANAGER)
    {
        (D18 last,) = shareClassManager.pricePoolPerShare(poolP, scP);
        uint256 elapsed = block.timestamp - ghostStrictPriceAnchor;
        // A third re-commit the price, a third range over the absolute bound and a third over the rate bound
        uint256 move;
        if (mode % 3 == 1) {
            move = between(moveSeed, 1, 2 * STRICT_MAX_PRICE_DELTA);
        } else if (mode % 3 == 2) {
            uint256 atRate = 2 * STRICT_PRICE_RATE * MathLib.max(elapsed, 1);
            move = between(moveSeed, 1, MathLib.min(atRate, 2 * STRICT_MAX_PRICE_DELTA));
        }
        uint128 price = uint128(up ? last.raw() + move : last.raw() - MathLib.min(move, last.raw() - 1));
        uint256 delta = up ? price - last.raw() : last.raw() - price;

        bool instant = ghostStrictPriceAnchor == 0 || delta == 0
            || (elapsed != 0 && delta < STRICT_MAX_PRICE_DELTA && delta / elapsed < STRICT_PRICE_RATE);
        bool sent = _sendUnderPolicy(address(priceManager), _priceCall(d18(price)), instant, authorized, true);
        if (!sent) return _reverted("strict_updateSharePrice");

        if (delta != 0 || ghostStrictPriceAnchor == 0) ghostStrictPriceAnchor = uint64(block.timestamp);
        (D18 committed,) = shareClassManager.pricePoolPerShare(poolP, scP);
        eq(committed.raw(), price, "an executed price update did not commit its price");
        _ok(instant ? bytes32("strict_priceInPolicy") : bytes32("strict_priceAuthorized"));
    }

    function _priceCall(D18 price) internal view returns (bytes memory) {
        return abi.encodeWithSignature(
            "updateSharePrice(uint64,bytes16,uint128,uint64)", poolP, scP, price, uint64(block.timestamp)
        );
    }

    /// @dev Sends `data` as `caller` and checks the hub against `instant`: the policy classifies the call the same
    ///      way, a call in policy never waits, and one outside it is refused as unauthorized unless an authorization
    ///      for exactly this call matured. A `wellFormed` call the policy admits must also go through.
    function _sendUnderPolicy(address caller, bytes memory data, bool instant, bool authorized, bool wellFormed)
        internal
        returns (bool success)
    {
        uint48 delay = strictPolicy.authorizationDelay(poolP, caller, data);
        eq(delay, instant ? 0 : strictPolicy.delay(), "the strict policy classified a call another way");
        if ((delay == 0) != instant) return false;

        bytes32 id = hubRegistry.authId(poolP, data);
        if (hubRegistry.authorizedAfter(id) != 0) hubRegistry.cancelAuthorization(poolP, caller, data);
        if (!instant && authorized) {
            hubRegistry.initiateAuthorization(poolP, caller, data);
            vm.warp(hubRegistry.authorizedAfter(id));
        }

        vm.deal(caller, 1 ether);
        bytes memory ret;
        (success, ret) = _callAs(caller, address(hub), data);
        bool refused = !success && bytes4(ret) == IHubRegistry.Unauthorized.selector;
        if (instant) t(!refused, "a call in policy waited for an authorization");
        else if (authorized) t(!refused, "a matured authorization was refused");
        else t(refused, "a call out of policy went through without an authorization");
        if (wellFormed && (instant || authorized)) t(success, "a call the policy admits did not go through");
    }
}
