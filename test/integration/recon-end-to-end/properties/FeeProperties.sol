// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {Asserts} from "@chimera/Asserts.sol";
import {BeforeAfter} from "../BeforeAfter.sol";

/// @notice The instant lane's fee, conserved: what the caller gives up is what the escrow books plus what the fee
///         recipient is paid, and what the recipient is paid is what the policy quotes.
/// @dev    Checked per action by the instant handlers (`_feeBegin`, `_feeEnd`), under the reserve policy, which never
///         rebates, so the recipient's balance only rises. A fee with no recipient is retained: nothing reaches the
///         recipient and the escrow books everything the caller paid. Actions that draw on or feed pool C's vault
///         through a route are not checked, since that vault's own fee reaches the same recipient inside the call;
///         the recipient's movement there is booked in `ghost_feeUncovered`.
abstract contract FeeProperties is BeforeAfter, Asserts {
    struct FeeProbe {
        bool armed;
        uint256 recipientBefore;
        uint256 holdingBefore;
        uint256 poolCSupply;
        uint256 callerAssets;
        uint256 receiverAssets;
    }

    /// @dev The whole sequence: what the recipient received in checked actions is exactly what the policy quoted for
    ///      them, and its balance is those receipts plus what moved it outside them.
    function property_feeRecipientReceivedTheQuotedFees() public {
        eq(ghost_feeReceived, ghost_feeQuoted, "the fee recipient received other than the sum of the quoted fees");
        t(
            int256(usdc.balanceOf(FEE_RECIPIENT)) == int256(ghost_feeReceived) + ghost_feeUncovered,
            "the fee recipient's balance != its receipts"
        );
    }

    /// @dev A call that settles a request or claims one pays the recipient nothing of its own: no instant lane takes
    ///      part in it. The recipient is paid there only where an action went unchecked (one not under the reserve
    ///      policy, or one the recipient is a party to) or where pool C's shares moved, since a route draws on or feeds
    ///      pool C's vault, whose own fee reaches the recipient inside the call. Any other payout is in a path no
    ///      per-action check judges. A handler that trades instantly through a router is not told apart, so it is not
    ///      judged here.
    function _checkFeeGap(int256 gap) internal override {
        if (gap == 0 || !_feeNoInstantInCall || _feeSkippedInCall || shareC.totalSupply() != _feePoolCSupplyBefore) {
            return;
        }
        t(false, "the fee recipient was paid outside a checked instant action");
    }

    function _feeBegin(IAsyncVault vault, address caller, address receiver) internal returns (FeeProbe memory p) {
        p.armed = address(vault.instantPolicy()) == address(reserveInstantPolicy) && caller != FEE_RECIPIENT
            && receiver != FEE_RECIPIENT;
        if (!p.armed) {
            _feeSkippedInCall = true;
            return p;
        }
        p.recipientBefore = usdc.balanceOf(FEE_RECIPIENT);
        (p.holdingBefore,) = _escrow(poolA).holding(scA, address(usdc), 0);
        p.poolCSupply = shareC.totalSupply();
        p.callerAssets = usdc.balanceOf(caller);
        p.receiverAssets = usdc.balanceOf(receiver);
    }

    /// @dev `flag` is `byShares` on the deposit side and `byAssets` on the redeem side, `amount` what the call named.
    function _feeEnd(
        FeeProbe memory p,
        IAsyncVault vault,
        address caller,
        address receiver,
        uint256 amount,
        bool flag,
        bool isDeposit
    ) internal {
        if (!p.armed) return;
        if (shareC.totalSupply() != p.poolCSupply) {
            _feeSkippedInCall = true;
            return;
        }

        uint256 recipientAfter = usdc.balanceOf(FEE_RECIPIENT);
        t(recipientAfter >= p.recipientBefore, "an instant action took assets from the fee recipient");
        uint256 received = _floorSub(recipientAfter, p.recipientBefore);

        (address recipient,,,,,,) = reserveInstantPolicy.config(address(vault));
        uint256 quoted;
        if (recipient != address(0)) {
            quoted = isDeposit
                ? _depositQuote(p, vault, caller, receiver, amount, flag, received)
                : _redeemQuote(p, vault, caller, receiver, flag, received);
        }
        if (isDeposit) _depositIsConserved(p, caller, received);
        eq(received, quoted, "the fee recipient was not paid the quoted fee");

        ghost_feeReceived += received;
        ghost_feeQuoted += quoted;
        _feeCoveredInCall += received;
    }

    /// @dev What the caller paid is what the escrow booked plus the fee paid out, a retained fee being booked.
    function _depositIsConserved(FeeProbe memory p, address caller, uint256 received) internal {
        uint256 paid = _floorSub(p.callerAssets, usdc.balanceOf(caller));
        (uint256 holding,) = _escrow(poolA).holding(scA, address(usdc), 0);
        eq(paid, _floorSub(holding, p.holdingBefore) + received, "a deposit's payment != escrowed + fee paid");
    }

    /// @dev The policy's fee on what the deposit named: the assets, or for a mint the shares' value, which is what
    ///      the caller paid less the fee.
    function _depositQuote(
        FeeProbe memory p,
        IAsyncVault vault,
        address caller,
        address receiver,
        uint256 amount,
        bool byShares,
        uint256 received
    ) internal view returns (uint256) {
        uint256 base = byShares ? _floorSub(_floorSub(p.callerAssets, usdc.balanceOf(caller)), received) : amount;
        (int128 fee,) =
            reserveInstantPolicy.quoteInstantDeposit(address(vault), caller, receiver, uint128(base), byShares);
        return uint256(int256(fee));
    }

    /// @dev The policy's fee on what the redemption named: the payout for a withdraw, the payout and the fee, which
    ///      is the shares' value, for a redeem.
    function _redeemQuote(
        FeeProbe memory p,
        IAsyncVault vault,
        address caller,
        address receiver,
        bool byAssets,
        uint256 received
    ) internal view returns (uint256) {
        uint256 payout = _floorSub(usdc.balanceOf(receiver), p.receiverAssets);
        uint256 base = byAssets ? payout : payout + received;
        (int128 fee,) =
            reserveInstantPolicy.quoteInstantRedeem(address(vault), caller, receiver, uint128(base), byAssets);
        return uint256(int256(fee));
    }
}
