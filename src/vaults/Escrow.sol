// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";
import {Holding, IPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";

contract Escrow is Auth, IEscrow {
    constructor(address deployer) Auth(deployer) {}

    /// @inheritdoc IEscrow
    function authTransferTo(address asset, uint256 tokenId, address receiver, uint256 amount) public auth {
        if (tokenId == 0) {
            uint256 balance = IERC20(asset).balanceOf(address(this));
            require(balance >= amount, InsufficientBalance(asset, tokenId, amount, balance));

            SafeTransferLib.safeTransfer(asset, receiver, amount);
        } else {
            uint256 balance = IERC6909(asset).balanceOf(address(this), tokenId);
            require(balance >= amount, InsufficientBalance(asset, tokenId, amount, balance));

            IERC6909(asset).transfer(receiver, tokenId, amount);
        }

        emit AuthTransferTo(asset, tokenId, receiver, amount);
    }

    /// @inheritdoc IEscrow
    function authTransferTo(address asset, address receiver, uint256 amount) external auth {
        authTransferTo(asset, 0, receiver, amount);
    }
}

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

    receive() external payable {}

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
    function reserveIncrease(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external auth {
        uint128 newValue = holding[scId][asset][tokenId].reserved + value;
        holding[scId][asset][tokenId].reserved = newValue;

        emit IncreaseReserve(asset, tokenId, poolId, scId, value, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function reserveDecrease(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external auth {
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
