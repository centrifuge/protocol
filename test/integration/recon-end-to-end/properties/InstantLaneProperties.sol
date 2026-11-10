// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ClaimLedgerProperties} from "./ClaimLedgerProperties.sol";

import {D18} from "../../../../src/misc/types/D18.sol";
import {MathLib} from "../../../../src/misc/libraries/MathLib.sol";

import {IAsyncVault} from "../../../../src/vaults/interfaces/IAsyncVault.sol";

import {vm} from "@chimera/Hevm.sol";

/// @notice What an action on one vault must leave alone: the other holders' value on the instant lane, and the
///         request ledgers of the sibling vaults of the same pool and share class.
/// @dev    The vaults price at the oracle and never at a balance ratio (`SPECIFICATION.md`, "Share price is a
///         valuation"), so an instant trade cannot move a holder's value per share. What it can do is mint or burn
///         shares at a value that does not match the assets that moved, which is a transfer from the holders who stay.
///         The specification rounds every conversion in the pool's favor: shares minted floor, assets paid out floor,
///         shares burned and assets taken ceil, and fees round up. With a fee that is never a rebate (the shipped
///         `ReserveInstantPolicy` only skims), the caller therefore never takes out more value than it puts in.
abstract contract InstantLaneProperties is ClaimLedgerProperties {
    /// @dev How many actions were judged on their siblings' ledgers, and how many trades on a bystander's value.
    uint256 internal ghost_siblingChecks;
    uint256 internal ghost_dilutionChecks;

    struct Bystander {
        address who;
        uint256 shares;
        uint256 value;
        uint256 price;
    }

    /// @dev A sibling's ledgers must be as they were after any action on a vault of the same pool and share class
    ///      that is not through the shared escrow.
    struct SiblingSnap {
        bool on;
        Req[] ids;
        bytes32[] before;
    }

    /// @dev Below this much gas left the check is skipped, so judging siblings never starves the action itself.
    uint256 internal constant SIBLING_MIN_GAS = 6_000_000;

    modifier siblingsUntouched(IAsyncVault vault) {
        SiblingSnap memory snap = _siblingBegin();
        _;
        _siblingEnd(vault, snap);
    }

    /// @dev The requests are fixed before the action: tracking a new request may compact the list, and a bucket that
    ///      leaves it between the two hashes would look like a change.
    function _siblingBegin() internal returns (SiblingSnap memory snap) {
        if (siblingBudget == 0 || gasleft() < SIBLING_MIN_GAS) return snap;
        siblingBudget--;
        snap.on = true;
        snap.ids = reqs;
        snap.before = _ledgerPrints(snap.ids);
    }

    function _siblingEnd(IAsyncVault vault, SiblingSnap memory snap) internal {
        if (!snap.on) return;
        bytes32[] memory after_ = _ledgerPrints(snap.ids);
        ghost_siblingChecks++;
        uint256 acting = _vaultPosition(vault);
        for (uint256 i; i < after_.length; i++) {
            if (i != acting) {
                t(snap.before[i] == after_[i], "an action on one vault changed a sibling vault's ledgers");
            }
        }
    }

    //----------------------------------------------------------------------------------------------
    // Non-dilution
    //----------------------------------------------------------------------------------------------

    /// @dev A holder other than `caller`, from the sample counter on, with what its shares are worth.
    function _bystander(IAsyncVault vault, address caller) internal view returns (Bystander memory b) {
        for (uint256 i; i < actors.length; i++) {
            address a = actors[(sampleCounter + i) % actors.length];
            if (a == caller || shareA.balanceOf(a) == 0) continue;
            b.who = a;
            b.shares = shareA.balanceOf(a);
            break;
        }
        (b.value, b.price) = _valueOf(vault, b.shares);
    }

    /// @dev The vault's own conversion of `shares` and its price per share, zero where the vault refuses to read.
    function _valueOf(IAsyncVault vault, uint256 shares) internal view returns (uint256 value, uint256 price) {
        try vault.convertToAssets(shares) returns (uint256 v) {
            value = v;
        } catch {}
        try vault.pricePerShare() returns (uint256 p) {
            price = p;
        } catch {}
    }

    /// @dev After an instant trade by someone else: the bystander holds the same shares, each worth what it was, and
    ///      the caller took out no more value than it put in. Only for the shipped policy, which never rebates; a
    ///      policy that does can pay the caller above the oracle value by design.
    function _checkNonDilution(
        IAsyncVault vault,
        Bystander memory b,
        address caller,
        uint256 sharesBefore,
        uint256 assetsBefore,
        bool isDeposit
    ) internal {
        if (address(vault.instantPolicy()) != address(reserveInstantPolicy)) return;
        if (b.who != address(0)) {
            ghost_dilutionChecks++;
            (uint256 value, uint256 price) = _valueOf(vault, b.shares);
            eq(shareA.balanceOf(b.who), b.shares, "an instant trade moved a bystander's shares");
            eq(price, b.price, "an instant trade moved the price per share");
            gte(value, b.value, "an instant trade lowered a bystander's value");
        }

        _checkValueOut(vault, caller, sharesBefore, assetsBefore, isDeposit);
    }

    /// @dev What the caller took out, valued at the oracle, against what it put in net of the fee.
    function _checkValueOut(
        IAsyncVault vault,
        address caller,
        uint256 sharesBefore,
        uint256 assetsBefore,
        bool isDeposit
    ) internal {
        (D18 ppa, D18 pps, bool valid) = spokeOracle.prices(poolA, scA, usdcId);
        if (!valid) return;
        uint256 shares = isDeposit
            ? _floorSub(shareA.balanceOf(caller), sharesBefore)
            : _floorSub(sharesBefore, shareA.balanceOf(caller));
        uint256 assets = isDeposit
            ? _backing(vault, _floorSub(assetsBefore, usdc.balanceOf(caller)))
            : _grossed(vault, _floorSub(usdc.balanceOf(caller), assetsBefore));
        // assets * ppa / 10^assetDecimals == shares * pps / 10^shareDecimals, cross-multiplied so no side rounds
        (bool fits, uint256 shareSide, uint256 assetSide) = _sides(shares, pps, assets, ppa);
        if (!fits) return;
        if (isDeposit) lte(shareSide, assetSide, "an instant deposit minted shares worth more than the assets paid");
        else lte(assetSide, shareSide, "an instant redemption paid more than the shares burned were worth");
    }

    /// @dev The most of `paid` that can back shares once the policy's fee is out: `paid` less the fee on the gross, the
    ///      fee rounded up, so the exact-in and exact-out forms both land on it or below.
    function _backing(IAsyncVault vault, uint256 paid) internal view returns (uint256) {
        (, uint16 depositBps,,,,,) = reserveInstantPolicy.config(address(vault));
        return MathLib.mulDiv(paid, MathLib.BPS - depositBps, MathLib.BPS);
    }

    /// @dev The least the shares burned were worth, given what was paid out: `paid` plus the fee, which the policy
    ///      grosses up and rounds up, so the exact-in and exact-out forms both burn at least this.
    function _grossed(IAsyncVault vault, uint256 paid) internal view returns (uint256) {
        (,, uint16 redeemBps,,,,) = reserveInstantPolicy.config(address(vault));
        return MathLib.mulDiv(paid, MathLib.BPS, MathLib.BPS - redeemBps, MathLib.Rounding.Up);
    }

    /// @dev `shares * pps * 10^assetDecimals` and `assets * ppa * 10^shareDecimals`, both divided by the smaller power
    ///      of ten; `fits` is false where a product would not fit a word, which no clamped amount reaches.
    function _sides(uint256 shares, D18 pps, uint256 assets, D18 ppa)
        internal
        pure
        returns (bool fits, uint256 shareSide, uint256 assetSide)
    {
        uint256 shareScale = ONE_ASSET >= ONE_SHARE ? ONE_ASSET / ONE_SHARE : 1;
        uint256 assetScale = ONE_SHARE >= ONE_ASSET ? ONE_SHARE / ONE_ASSET : 1;
        bool a;
        bool b;
        bool c;
        bool d;
        (a, shareSide) = _product(shares, pps.raw());
        (b, shareSide) = _product(shareSide, shareScale);
        (c, assetSide) = _product(assets, ppa.raw());
        (d, assetSide) = _product(assetSide, assetScale);
        fits = a && b && c && d;
    }

    function _product(uint256 x, uint256 y) internal pure returns (bool fits, uint256 z) {
        unchecked {
            z = x * y;
        }
        fits = x == 0 || z / x == y;
    }

    //----------------------------------------------------------------------------------------------
    // Sibling isolation
    //----------------------------------------------------------------------------------------------

    /// @dev One hash per pool A vault of what its controllers hold and its buckets owe: the investment ledger as the
    ///      vault stores it (what is paid, refunded and folded), the pending and claimable views, and every tracked
    ///      bucket with its queue.
    function _ledgerPrints(Req[] memory ids) internal returns (bytes32[] memory h) {
        h = new bytes32[](vaults.length);
        for (uint256 v; v < vaults.length; v++) {
            for (uint256 a; a < actors.length; a++) {
                bytes32 base = keccak256(abi.encode(actors[a], INVESTMENTS_SLOT));
                h[v] = keccak256(
                    abi.encode(
                        h[v],
                        vm.load(address(vaults[v]), base),
                        vm.load(address(vaults[v]), bytes32(uint256(base) + 1)),
                        vm.load(address(vaults[v]), bytes32(uint256(base) + 2)),
                        vaults[v].pendingDepositRequest(0, actors[a]),
                        vaults[v].pendingRedeemRequest(0, actors[a]),
                        vaults[v].claimableMint(actors[a]),
                        vaults[v].claimableWithdraw(actors[a])
                    )
                );
            }
        }
        for (uint256 i; i < ids.length; i++) {
            uint96 localId = uint96(ids[i].requestId);
            IAsyncVault vault = vaults[ids[i].vault];
            h[ids[i].vault] = keccak256(abi.encode(h[ids[i].vault], localId, vault.bucket(localId)));
        }
    }

    /// @dev The position of `vault` among pool A's vaults, or their count for any other.
    function _vaultPosition(IAsyncVault vault) internal view returns (uint256 i) {
        for (; i < vaults.length; i++) {
            if (address(vaults[i]) == address(vault)) return i;
        }
    }
}
