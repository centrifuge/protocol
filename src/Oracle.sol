// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity = 0.8.28;

import {IERC7726, IERC7726} from "src/interfaces/IERC7726.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IOracle, IOracleFactory} from "src/interfaces/IOracle.sol";
import {MathLib} from "src/libraries/MathLib.sol";

/// @notice Quote value representation value representation
struct Quote {
    /// @notice Price of one base in quote denomination
    uint256 amount;
    /// @notice Timestamp when the value was fed
    uint64 referenceTime;
}

contract Oracle is IOracle {
    /// @notice Default decimal representation when `base` is not an ERC20.
    uint8 public constant DEFAULT_DECIMALS = 18;

    /// @notice Owner of the contract able to feed new values
    address public feeder;

    /// @notice All fed values.
    mapping(address base => mapping(address quote => Quote)) public values;

    constructor(address feeder_) {
        feeder = feeder_;
    }

    /// @dev check that only the feeder perform the action
    modifier onlyFeeder() {
        require(msg.sender == feeder, NotValidFeeder());
        _;
    }

    /// @inheritdoc IOracle
    function setQuote(address base, address quote, uint256 quoteAmount) external onlyFeeder {
        uint64 referenceTime = uint64(block.timestamp);
        values[base][quote] = Quote(quoteAmount, referenceTime);

        emit NewQuoteSet(base, quote, quoteAmount, referenceTime);
    }

    /// @inheritdoc IERC7726
    function getQuote(uint256 baseAmount, address base, address quote) external view returns (uint256 quoteAmount) {
        Quote storage quoteValue = values[base][quote];
        require(quoteValue.referenceTime > 0, NoQuote());

        return MathLib.mulDiv(baseAmount, quoteValue.amount, 10 ** _extractDecimals(base));
    }

    /// @dev extract the decimals used for the assetId
    /// - If the asset is an ERC20, then we ask the contract for its decimals
    /// - Otherwise we assume 18 decimals
    function _extractDecimals(address assetId) internal view returns (uint8) {
        if (assetId.code.length == 0) {
            return DEFAULT_DECIMALS;
        } else {
            (bool ok, bytes memory data) = assetId.staticcall(abi.encodeWithSelector(IERC20.decimals.selector));
            if (ok) {
                return abi.decode(data, (uint8));
            } else {
                return DEFAULT_DECIMALS;
            }
        }
    }
}

contract OracleFactory is IOracleFactory {
    /// @inheritdoc IOracleFactory
    function deploy(address feeder, bytes32 salt) external returns (IOracle) {
        Oracle deployed = new Oracle{salt: salt}(feeder);

        emit NewOracleDeployed(address(deployed));

        return deployed;
    }

    /// @inheritdoc IOracleFactory
    function getAddress(address feeder, bytes32 salt) public view returns (address) {
        bytes memory bytecode = abi.encodePacked(type(Oracle).creationCode, abi.encode(feeder));

        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(bytecode)))))
        );
    }
}
