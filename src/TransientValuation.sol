// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {D18} from "src/types/D18.sol";

import {Conversion} from "src/libraries/Conversion.sol";

import {IERC7726} from "src/interfaces/IERC7726.sol";
import {ITransientValuation} from "src/interfaces/ITransientValuation.sol";
import {IERC6909MetadataExt} from "src/interfaces/ERC6909/IERC6909MetadataExt.sol";

import {BaseValuation} from "src/BaseValuation.sol";

contract TransientValuation is BaseValuation, ITransientValuation {
    /// @notice Temporal price set and used to obtain the quote.
    D18 public /*TODO: transient*/ price;

    constructor(IERC6909MetadataExt erc6909, address deployer) BaseValuation(erc6909, deployer) {}

    /// @inheritdoc ITransientValuation
    function setPrice(D18 price_) external {
        price = price_;
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        return Conversion.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), price);
    }
}
