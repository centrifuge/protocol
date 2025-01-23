// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AssetId} from "src/types/AssetId.sol";
import {D18} from "src/types/D18.sol";

import {Conversion} from "src/libraries/Conversion.sol";

import {IERC7726} from "src/interfaces/IERC7726.sol";
import {ITransientValuation} from "src/interfaces/ITransientValuation.sol";
import {IAssetManager} from "src/interfaces/IAssetManager.sol";

import {BaseERC7726} from "src/BaseERC7726.sol";

contract TransientValuation is BaseERC7726, ITransientValuation {
    /// @notice Temporal price set and used to obtain the quote.
    D18 public /*TODO: transient*/ price;

    constructor(IAssetManager assetManager, address deployer) BaseERC7726(assetManager, deployer) {}

    /// @inheritdoc ITransientValuation
    function setPrice(D18 price_) external {
        price = price_;
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        return Conversion.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), price);
    }
}
