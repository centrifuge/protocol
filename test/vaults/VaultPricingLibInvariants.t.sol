// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {MathLib} from "../../src/misc/libraries/MathLib.sol";

import {InvestmentState} from "../../src/vaults/interfaces/IAsyncVault.sol";
import {VaultPricingLib} from "../../src/vaults/libraries/VaultPricingLib.sol";

import "forge-std/Test.sol";

/// @dev Drives a claimable ledger the way the vault does: fills on both sides (including the zero-leg
///      credits a cross-side cancellation makes) and claims in either unit, priced pro-rata with
///      `VaultPricingLib.slice` in the vault's rounding directions. Amounts are log-uniform from 1 wei.
contract LedgerHandler is Test {
    uint128 public constant CAP = type(uint128).max / 4;

    InvestmentState public state;

    // Everything ever filled and everything ever paid, per unit and side
    uint256 public filledMint;
    uint256 public filledDepositAssets;
    uint256 public filledWithdraw;
    uint256 public filledRedeemShares;
    uint256 public paidShares;
    uint256 public chargedAssets;
    uint256 public paidAssets;
    uint256 public chargedShares;

    uint256 public fullClaims;

    function _amount(uint256 seed, uint256 max) internal pure returns (uint128) {
        if (max == 0) return 0;
        uint256 magnitude = 10 ** _bound(seed % 39, 0, 38);
        return uint128(_bound(seed >> 8, 0, MathLib.min(magnitude, max)));
    }

    function fillDeposit(uint256 sharesSeed, uint256 assetsSeed) external {
        uint128 shares = _amount(sharesSeed, CAP - filledMint);
        uint128 assets = assetsSeed % 8 == 0 ? 0 : _amount(assetsSeed, CAP - filledDepositAssets);
        state.depositShares += shares;
        state.depositAssets += assets;
        filledMint += shares;
        filledDepositAssets += assets;
    }

    function fillRedeem(uint256 sharesSeed, uint256 assetsSeed) external {
        uint128 assets = _amount(assetsSeed, CAP - filledWithdraw);
        uint128 shares = sharesSeed % 8 == 0 ? 0 : _amount(sharesSeed, CAP - filledRedeemShares);
        state.redeemAssets += assets;
        state.redeemShares += shares;
        filledWithdraw += assets;
        filledRedeemShares += shares;
    }

    /// @dev `deposit` (by assets, shares floored) or `mint` (by shares, assets rounded up).
    function claimDeposit(uint256 seed, bool byAssets) external {
        uint128 maxMint = state.depositShares;
        uint128 assets = state.depositAssets;
        if (byAssets) {
            uint128 part = _part(seed, assets);
            if (part == 0) return;
            uint128 shares = uint128(MathLib.fractionOf(maxMint, part, assets, MathLib.Rounding.Down));
            state.depositAssets = assets - part;
            state.depositShares = maxMint - shares;
            paidShares += shares;
            chargedAssets += part;
        } else {
            uint128 part = _part(seed, maxMint);
            uint128 charged = uint128(MathLib.fractionOf(assets, part, maxMint, MathLib.Rounding.Up));
            state.depositShares = maxMint - part;
            state.depositAssets = assets - charged;
            paidShares += part;
            chargedAssets += charged;
        }
        if (state.depositShares == 0 && state.depositAssets == 0) fullClaims++;
    }

    /// @dev `redeem` (by shares, assets floored) or `withdraw` (by assets, shares rounded up).
    function claimRedeem(uint256 seed, bool byShares) external {
        uint128 maxWithdraw = state.redeemAssets;
        uint128 shares = state.redeemShares;
        if (byShares) {
            uint128 part = _part(seed, shares);
            if (part == 0) return;
            uint128 assets = uint128(MathLib.fractionOf(maxWithdraw, part, shares, MathLib.Rounding.Down));
            state.redeemShares = shares - part;
            state.redeemAssets = maxWithdraw - assets;
            paidAssets += assets;
            chargedShares += part;
        } else {
            uint128 part = _part(seed, maxWithdraw);
            uint128 charged = uint128(MathLib.fractionOf(shares, part, maxWithdraw, MathLib.Rounding.Up));
            state.redeemAssets = maxWithdraw - part;
            state.redeemShares = shares - charged;
            paidAssets += part;
            chargedShares += charged;
        }
    }

    /// @dev Half the time the whole balance, otherwise any part of it.
    function _part(uint256 seed, uint128 balance) internal pure returns (uint128) {
        if (balance == 0) return 0;
        return seed % 2 == 0 ? balance : uint128(_bound(seed >> 1, 1, balance));
    }
}

/// @dev The ledger conserves both units exactly: what is still claimable plus what was paid is what
///      was filled, per unit and side, whatever the order and size of the fills and claims.
contract VaultPricingLibInvariantsTest is Test {
    LedgerHandler handler;

    function setUp() public {
        handler = new LedgerHandler();
        targetContract(address(handler));
    }

    function invariant_depositSideIsConserved() public view {
        (uint128 maxMint, uint128 depositAssets,,,,) = handler.state();
        assertEq(uint256(maxMint) + handler.paidShares(), handler.filledMint(), "shares");
        assertEq(uint256(depositAssets) + handler.chargedAssets(), handler.filledDepositAssets(), "assets");
    }

    function invariant_redeemSideIsConserved() public view {
        (,, uint128 maxWithdraw, uint128 redeemShares,,) = handler.state();
        assertEq(uint256(maxWithdraw) + handler.paidAssets(), handler.filledWithdraw(), "assets");
        assertEq(uint256(redeemShares) + handler.chargedShares(), handler.filledRedeemShares(), "shares");
    }
}
