// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {AssetId} from "../types/AssetId.sol";

/// Based on [ERC-7726](https://eips.ethereum.org/EIPS/eip-7726): Common Quote Oracle, but adapted for ERC6909.
/// Interface for asset conversions.
interface IValuation {
    /// @notice Returns the value of baseAmount of base in quote terms, e.g. 10 ETH (base) in USDC (quote).
    /// @param base The asset in which the baseAmount is denominated in
    /// @param quote The asset in which the user needs to value the baseAmount
    /// @param baseAmount The amount of base in base terms.
    function getQuote(uint128 baseAmount, AssetId base, AssetId quote) external view returns (uint128 quoteAmount);
}
