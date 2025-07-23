// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "./types/PoolId.sol";
import {ShareClassId} from "./types/ShareClassId.sol";
import {Holding, IPoolEscrow} from "./interfaces/IPoolEscrow.sol";

import {Escrow} from "../misc/Escrow.sol";
import {Recoverable} from "../misc/Recoverable.sol";

/// @title  Escrow
/// @notice Escrow contract that holds assets for a specific pool separated by share classes.
///         Only wards can approve funds to be taken out.
contract PoolEscrow is Escrow, Recoverable, IPoolEscrow {
    /// @dev The underlying pool id
    PoolId public immutable poolId;

    mapping(ShareClassId scId => mapping(address asset => mapping(uint256 tokenId => Holding))) public holding;

    constructor(PoolId poolId_, address deployer) Escrow(deployer) {
        poolId = poolId_;
    }

    receive() external payable {
        emit ReceiveNativeTokens(msg.sender, msg.value);
    }

    /// @inheritdoc IPoolEscrow
    function deposit(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external auth {
        holding[scId][asset][tokenId].total += value;

        emit Deposit(asset, tokenId, poolId, scId, value);
    }

    /// @inheritdoc IPoolEscrow
    function withdraw(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external auth {
        Holding storage holding_ = holding[scId][asset][tokenId];
        uint128 balance = holding_.total - holding_.reserved;
        require(balance >= value, InsufficientBalance(asset, tokenId, value, balance));

        holding_.total -= value;

        emit Withdraw(asset, tokenId, poolId, scId, value);
    }

    /// @inheritdoc IPoolEscrow
    function reserve(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external auth {
        uint128 newValue = holding[scId][asset][tokenId].reserved + value;
        holding[scId][asset][tokenId].reserved = newValue;

        emit IncreaseReserve(asset, tokenId, poolId, scId, value, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function unreserve(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external auth {
        uint128 prevValue = holding[scId][asset][tokenId].reserved;
        uint128 value_ = value;
        require(prevValue >= value_, InsufficientReservedAmount());

        uint128 newValue = prevValue - value_;
        holding[scId][asset][tokenId].reserved = newValue;

        emit DecreaseReserve(asset, tokenId, poolId, scId, value, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function availableBalanceOf(ShareClassId scId, address asset, uint256 tokenId) public view returns (uint128) {
        Holding storage holding_ = holding[scId][asset][tokenId];
        if (holding_.total < holding_.reserved) return 0;
        return holding_.total - holding_.reserved;
    }
}
