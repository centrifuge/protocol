// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {MessageType, MessageLib} from "src/common/libraries/MessageLib.sol";

import {IGasService} from "src/vaults/interfaces/gateway/IGasService.sol";

/// @title  GasService
/// @notice This is a utility contract used in calculations of the
///         transaction cost for a message / proof being sent across all supported adapters
///         and executed on Centrifuge Chain.
contract GasService is IGasService, Auth {
    using MathLib for uint64;
    using MathLib for uint256;
    using BytesLib for bytes;
    using MessageLib for *;

    /// @dev Prices are fixed-point integers with 18 decimals
    uint256 internal constant PRICE_DENOMINATOR = 10 ** 18;

    /// @inheritdoc IGasService
    uint64 public proofCost;
    /// @inheritdoc IGasService
    uint64 public messageCost;
    /// @inheritdoc IGasService
    uint128 public gasPrice;
    /// @inheritdoc IGasService
    uint64 public lastUpdatedAt;
    /// @inheritdoc IGasService
    uint256 public tokenPrice;

    constructor(uint64 messageCost_, uint64 proofCost_, uint128 gasPrice_, uint256 tokenPrice_) Auth(msg.sender) {
        messageCost = messageCost_;
        proofCost = proofCost_;
        gasPrice = gasPrice_;
        tokenPrice = tokenPrice_;
        lastUpdatedAt = uint64(block.timestamp);
    }

    /// @inheritdoc IGasService
    function file(bytes32 what, uint64 value) external auth {
        if (what == "messageCost") messageCost = value;
        else if (what == "proofCost") proofCost = value;
        else revert("GasService/file-unrecognized-param");
        emit File(what, value);
    }

    /// --- Incoming message handling ---
    /// @inheritdoc IGasService
    function handle(bytes calldata message) public auth {
        MessageType kind = MessageLib.messageType(message);

        if (kind == MessageType.UpdateGasPrice) {
            MessageLib.UpdateGasPrice memory m = message.deserializeUpdateGasPrice();
            updateGasPrice(m.price, m.timestamp);
        } else {
            revert("GasService/invalid-message");
        }
    }

    /// --- Update methods ---
    /// @inheritdoc IGasService
    function updateGasPrice(uint128 value, uint64 computedAt) public auth {
        require(value != 0, "GasService/price-cannot-be-zero");
        require(gasPrice != value, "GasService/already-set-price");
        require(lastUpdatedAt < computedAt, "GasService/outdated-price");
        gasPrice = value;
        lastUpdatedAt = computedAt;
        emit UpdateGasPrice(value, computedAt);
    }

    /// @inheritdoc IGasService
    function updateTokenPrice(uint256 value) external auth {
        tokenPrice = value;
        emit UpdateTokenPrice(value);
    }

    /// --- Estimations ---
    /// @inheritdoc IGasService
    function estimate(bytes calldata payload) public view returns (uint256) {
        uint256 totalCost;
        uint8 kind = payload.toUint8(0);
        if (kind == uint8(MessageType.MessageProof)) {
            totalCost = proofCost.mulDiv(gasPrice, PRICE_DENOMINATOR, MathLib.Rounding.Up);
        } else {
            totalCost = messageCost.mulDiv(gasPrice, PRICE_DENOMINATOR, MathLib.Rounding.Up);
        }

        return totalCost.mulDiv(tokenPrice, PRICE_DENOMINATOR, MathLib.Rounding.Up);
    }

    /// @inheritdoc IGasService
    function shouldRefuel(address, bytes calldata) public pure returns (bool success) {
        success = true;
    }
}
