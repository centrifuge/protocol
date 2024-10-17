// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity = 0.8.28;

import {IERC7726, IERC7726} from "src/interfaces/IERC7726.sol";
import {IERC165} from "forge-std/interfaces/IERC165.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {MathLib} from "src/libraries/MathLib.sol";

contract Oracle is IERC7726 {
    error NotValidFeeder();
    error ValueNotFound();

    event Fed(address indexed base, address indexed quote, uint256 quoteAmount);

    struct Value {
        /// Price of one base in quote denomination
        uint256 amount;
        /// Timestamp when the value was fed
        uint64 referenceTime;
    }

    address feeder;
    mapping(address base => mapping(address quote => Value)) public values;

    modifier onlyFeeder() {
        require(msg.sender == feeder, NotValidFeeder());
        _;
    }

    constructor(address feeder_) {
        feeder = feeder_;
    }

    /// @notice Feed the system with a new base -> quote relation.
    /// @param base The identification of the base element
    /// @param quote The identification of the quote element
    /// @param quoteAmount The amount of 1 wei of base amount represented as quote units.
    function setQuote(address base, address quote, uint256 quoteAmount) external onlyFeeder {
        values[base][quote] = Value(quoteAmount, uint64(block.timestamp));

        emit Fed(base, quote, quoteAmount);
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        Value storage quoteValue = values[base][quote];
        require(quoteValue.referenceTime > 0, ValueNotFound());

        return MathLib.mulDiv(baseAmount, quoteValue.amount, 1 ** _extractDecimals(base));
    }

    /// @dev extract the decimals used for the assetId
    /// - If the asset is an ERC20, then we ask the contract for its decimals
    /// - Otherwise we assume 18 decimals
    function _extractDecimals(address assetId) internal view returns (uint8) {
        if (IERC165(assetId).supportsInterface(type(IERC20).interfaceId)) {
            IERC20 erc20 = IERC20(assetId);
            return erc20.decimals();
        } else {
            return 18;
        }
    }
}

contract OracleFactory {
    event NewOracle(address where);

    function build(address feeder) external {
        address deployed = address(new Oracle(feeder));

        emit NewOracle(deployed);
    }
}
