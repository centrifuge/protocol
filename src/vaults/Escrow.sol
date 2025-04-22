// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {MathLib} from "src/misc/libraries/MathLib.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {Recoverable} from "src/misc/Recoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";

import {Holding, IPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";

contract Escrow is Auth, IEscrow {
    constructor(address deployer) Auth(deployer) {}

    // --- Token approvals ---
    /// @inheritdoc IEscrow
    function approveMax(address asset, address spender) external auth {
        if (IERC20(asset).allowance(address(this), spender) == 0) {
            SafeTransferLib.safeApprove(asset, spender, type(uint256).max);
            emit Approve(asset, spender, type(uint256).max);
        }
    }

    /// @inheritdoc IEscrow
    function approveMax(address asset, uint256 tokenId, address spender) external auth {
        if (tokenId == 0) {
            if (IERC20(asset).allowance(address(this), spender) == 0) {
                SafeTransferLib.safeApprove(asset, spender, type(uint256).max);
                emit Approve(asset, spender, type(uint256).max);
            }
        } else {
            if (IERC6909(asset).allowance(address(this), spender, tokenId) == 0) {
                IERC6909(asset).approve(spender, tokenId, type(uint256).max);
                emit Approve(asset, tokenId, spender, type(uint256).max);
            }
        }
    }

    /// @inheritdoc IEscrow
    function unapprove(address asset, address spender) external auth {
        SafeTransferLib.safeApprove(asset, spender, 0);
        emit Approve(asset, spender, 0);
    }

    /// @inheritdoc IEscrow
    function unapprove(address asset, uint256 tokenId, address spender) external auth {
        if (tokenId == 0) {
            SafeTransferLib.safeApprove(asset, spender, 0);
            emit Approve(asset, spender, 0);
        } else {
            IERC6909(asset).approve(spender, tokenId, 0);
            emit Approve(asset, tokenId, spender, 0);
        }
    }
}

/// @title  Escrow
/// @notice Escrow contract that holds assets for a specific pool separated by share classes.
///         Only wards can approve funds to be taken out.
contract PoolEscrow is Escrow, Recoverable, IPoolEscrow {
    using MathLib for uint256;

    /// @dev The underlying pool id
    uint64 public immutable poolId;

    mapping(bytes16 scId => mapping(address asset => mapping(uint256 tokenId => Holding))) public holding;

    constructor(uint64 poolId_, address deployer) Escrow(deployer) {
        poolId = poolId_;
    }

    receive() external payable {}

    /// @inheritdoc IPoolEscrow
    function deposit(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        _deposit(scId, asset, tokenId, value, true);
    }

    /// @inheritdoc IPoolEscrow
    function noteDeposit(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        _deposit(scId, asset, tokenId, value, false);
    }

    /// @inheritdoc IPoolEscrow
    function withdraw(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        Holding storage holding_ = holding[scId][asset][tokenId];
        require(holding_.total - holding_.reserved >= value, InsufficientBalance());

        holding_.total -= value.toUint128();

        emit Withdraw(asset, tokenId, poolId, scId, value);
    }

    /// @inheritdoc IPoolEscrow
    function reserveIncrease(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        uint128 newValue = holding[scId][asset][tokenId].reserved + value.toUint128();
        holding[scId][asset][tokenId].reserved = newValue;

        emit IncreaseReserve(asset, tokenId, poolId, scId, value, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function reserveDecrease(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        uint128 prevValue = holding[scId][asset][tokenId].reserved;
        uint128 value_ = value.toUint128();
        require(prevValue >= value_, InsufficientReservedAmount());

        uint128 newValue = prevValue - value_;
        holding[scId][asset][tokenId].reserved = newValue;

        emit DecreaseReserve(asset, tokenId, poolId, scId, value, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function availableBalanceOf(bytes16 scId, address asset, uint256 tokenId) public view returns (uint256) {
        Holding storage holding_ = holding[scId][asset][tokenId];
        if (holding_.total < holding_.reserved) return 0;
        return holding_.total - holding_.reserved;
    }

    function _deposit(bytes16 scId, address asset, uint256 tokenId, uint256 value, bool checkSufficiency) internal {
        uint128 holding_ = holding[scId][asset][tokenId].total;

        // Leave out check for deposits which transfer funds post escrow.deposit due to security concerns
        if (checkSufficiency) {
            uint256 balance = tokenId == 0
                ? IERC20(asset).balanceOf(address(this))
                : IERC6909(asset).balanceOf(address(this), tokenId);
            require(balance >= holding_ + value, InsufficientDeposit());
        }

        holding[scId][asset][tokenId].total += value.toUint128();

        emit Deposit(asset, tokenId, poolId, scId, value);
    }
}
