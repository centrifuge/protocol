// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HubTargets} from "./HubTargets.sol";

import {IReserveInstantPolicy} from "../../../../src/vaults/policies/interfaces/IVaultPlugins.sol";

import {OpType} from "../BeforeAfter.sol";

/// @notice The parameters of pool C, the fund pool A invests in. Everything else the fuzzer re-terms (pool A's
///         prices, fees and lanes) is in `HubTargets`; pool C used to stay at par with a fixed fee, which left the
///         route's draw on it priced at one point only.
abstract contract ParamTargets is HubTargets {
    /// @dev Reprices pool C's share class and notifies it, so the route's `previewWithdraw` on pool C, the shares it
    ///      releases and the residual it hands back are sized at a price other than par, or refused at zero.
    function poolC_updateSharePrice(uint256 price, uint8 mode) public updateGhosts(OpType.PRICE) {
        _pushPrices(poolC, scC, _price(price, mode, 5e17, 4e18, 1e27));
        _ok("poolC_updateSharePrice");
    }

    /// @dev Re-terms pool C's instant lane: its fees (up to the policy's bound when `wide`), whether redemptions
    ///      are open, and the reserve its deposits fill. The route redeems through this lane, so a fee or a closed
    ///      lane changes what a draw can raise. Gates stay off, since a gated lane would only turn the route away.
    function poolC_configure(uint16 feeBps, uint256 flags, uint256 capSeed, bool wide)
        public
        updateGhosts(OpType.TERMS)
    {
        (address feeRecipient,,,,,,) = reserveInstantPolicy.config(address(vaultC));
        uint128 cap = capSeed % 6 == 0 ? 0 : uint128(between(capSeed, ACTOR_FUNDS / 10, ACTOR_FUNDS));
        if (wide) cap = uint128(_larger(_hugeAssets() / 4, ACTOR_FUNDS));
        uint256 maxFee = wide ? MAX_FEE_BPS : 500;
        bytes memory terms = abi.encode(
            feeRecipient,
            uint16(between(feeBps, 0, maxFee)),
            uint16(between(feeBps / 2, 0, maxFee)),
            flags % 8 != 0,
            false,
            false,
            cap
        );
        _managerCall(
            poolC,
            address(reserveInstantPolicy),
            abi.encode(IReserveInstantPolicy.ConfigKind.Terms, address(vaultC), terms)
        );
        _ok("poolC_configure");
    }
}
