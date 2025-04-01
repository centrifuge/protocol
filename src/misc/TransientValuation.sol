// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {D18, d18} from "src/misc/types/D18.sol";

import {ConversionLib} from "src/misc/libraries/ConversionLib.sol";
import {TransientStorage} from "src/misc/libraries/TransientStorage.sol";
import {ReentrancyProtection} from "src/misc/ReentrancyProtection.sol";
import {IERC7726} from "src/misc/interfaces/IERC7726.sol";
import {ITransientValuation} from "src/misc/interfaces/ITransientValuation.sol";
import {IERC6909MetadataExt} from "src/misc/interfaces/IERC6909.sol";

import {BaseValuation} from "src/misc/BaseValuation.sol";

contract TransientValuation is BaseValuation, ReentrancyProtection, ITransientValuation {
    using TransientStorage for bytes32;

    constructor(IERC6909MetadataExt erc6909, address deployer) BaseValuation(erc6909, deployer) {}

    /// @inheritdoc ITransientValuation
    function setPrice(address base, address quote, D18 price) external protected {
        bytes32 slot = keccak256(abi.encode(base, quote));
        slot.tstore(uint256(price.inner()));

        // @dev we assume symmetric prices
        slot = keccak256(abi.encode(quote, base));
        slot.tstore(uint256(price.reciprocal().inner()));
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        bytes32 slot = keccak256(abi.encode(base, quote));
        D18 price = d18(uint128(slot.tloadUint256()));

        require(D18.unwrap(price) != 0, PriceNotSet(base, quote));

        return ConversionLib.convertWithPrice(baseAmount, _getDecimals(base), _getDecimals(quote), price);
    }
}
