// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {ISharedDependency} from "src/misc/interfaces/ISharedDependency.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {IGateway} from "src/common/interfaces/IGateway.sol";

import {IPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";

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
contract PoolEscrow is Escrow, IPoolEscrow {
    /// @dev The underlying pool id
    uint64 immutable poolId;

    ISharedDependency immutable sharedGateway;

    mapping(bytes16 scId => mapping(address asset => mapping(uint256 tokenId => uint256))) internal reservedAmount;
    mapping(bytes16 scId => mapping(address asset => mapping(uint256 tokenId => uint256))) internal pendingDeposit;
    mapping(bytes16 scId => mapping(address asset => mapping(uint256 tokenId => uint256))) internal holding;

    constructor(uint64 poolId_, ISharedDependency sharedGateway_, address deployer) Escrow(deployer) {
        poolId = poolId_;
        sharedGateway = sharedGateway_;

        IGateway(sharedGateway.dependency()).setRefundAddress(PoolId.wrap(poolId), address(this));
    }

    receive() external payable {
        IGateway(sharedGateway.dependency()).subsidizePool{value: msg.value}(PoolId.wrap(poolId));
    }

    /// @inheritdoc IPoolEscrow
    function pendingDepositIncrease(bytes16 scId, address asset, uint256 tokenId, uint256 value)
        external
        override
        auth
    {
        uint256 newValue = pendingDeposit[scId][asset][tokenId] + value;
        pendingDeposit[scId][asset][tokenId] = newValue;

        emit PendingDeposit(asset, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function pendingDepositDecrease(bytes16 scId, address asset, uint256 tokenId, uint256 value)
        external
        override
        auth
    {
        require(pendingDeposit[scId][asset][tokenId] >= value, InsufficientPendingDeposit());

        uint256 newValue = pendingDeposit[scId][asset][tokenId] - value;
        pendingDeposit[scId][asset][tokenId] = newValue;

        emit PendingDeposit(asset, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function deposit(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        require(pendingDeposit[scId][asset][tokenId] >= value, InsufficientPendingDeposit());

        uint256 prevholding = holding[scId][asset][tokenId];
        if (tokenId == 0) {
            uint256 curholding = IERC20(asset).balanceOf(address(this));
            require(curholding >= prevholding + value, InsufficientDeposit());
        } else {
            uint256 curholding = IERC6909(asset).balanceOf(address(this), tokenId);
            require(curholding >= prevholding + value, InsufficientDeposit());
        }

        uint256 newPending = pendingDeposit[scId][asset][tokenId] - value;
        pendingDeposit[scId][asset][tokenId] = newPending;
        holding[scId][asset][tokenId] += value;

        emit Deposit(asset, tokenId, poolId, scId, value);
        emit PendingDeposit(asset, tokenId, poolId, scId, newPending);
    }

    /// @inheritdoc IPoolEscrow
    function reserveIncrease(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        uint256 newValue = reservedAmount[scId][asset][tokenId] + value;
        reservedAmount[scId][asset][tokenId] = newValue;

        emit Reserve(asset, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function reserveDecrease(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        require(reservedAmount[scId][asset][tokenId] >= value, InsufficientReservedAmount());

        uint256 newValue = reservedAmount[scId][asset][tokenId] - value;
        reservedAmount[scId][asset][tokenId] = newValue;

        emit Reserve(asset, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPoolEscrow
    function withdraw(bytes16 scId, address asset, uint256 tokenId, uint256 value) external auth {
        require(availableBalanceOf(scId, asset, tokenId) >= value, InsufficientBalance());

        holding[scId][asset][tokenId] -= value;

        emit Withdraw(asset, tokenId, poolId, scId, value);
    }

    /// @inheritdoc IPoolEscrow
    function availableBalanceOf(bytes16 scId, address asset, uint256 tokenId) public view returns (uint256) {
        uint256 holding_ = holding[scId][asset][tokenId];
        uint256 reservedAmount_ = reservedAmount[scId][asset][tokenId];

        if (holding_ < reservedAmount_) {
            return 0;
        } else {
            return holding_ - reservedAmount_;
        }
    }
}
