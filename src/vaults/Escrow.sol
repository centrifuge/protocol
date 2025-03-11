// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {IPerPoolEscrow, IEscrow} from "src/vaults/interfaces/IEscrow.sol";

/// @title  Escrow
/// @notice Escrow contract that holds tokens.
///         Only wards can approve funds to be taken out.
contract Escrow is Auth, IPerPoolEscrow, IEscrow {
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address token => mapping(uint256 tokenId => uint256))))
        internal reservedAmount;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address token => mapping(uint256 tokenId => uint256))))
        internal pendingDeposit;
    mapping(uint64 poolId => mapping(bytes16 scId => mapping(address token => mapping(uint256 tokenId => uint256))))
        internal holding;

    constructor(address deployer) Auth(deployer) {}

    // --- Token approvals ---
    /// @inheritdoc IEscrow
    function approveMax(address token, address spender) external auth {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            SafeTransferLib.safeApprove(token, spender, type(uint256).max);
            emit Approve(token, spender, type(uint256).max);
        }    }

    /// @inheritdoc IEscrow
    function approveMax(address token, uint256 tokenId, address spender) external auth {
        if (tokenId == 0) {
        if (IERC20(token).allowance(address(this), spender) == 0) {
            SafeTransferLib.safeApprove(token, spender, type(uint256).max);
            emit Approve(token, spender, type(uint256).max);
        }
        } else {
            if (IERC6909(token).allowance(address(this), spender, tokenId) == 0) {
                IERC6909(token).approve(spender, tokenId, type(uint256).max);
                emit Approve(token, tokenId, spender, type(uint256).max);
            }
        }
    }

    /// @inheritdoc IEscrow
    function unapprove(address token, address spender) external auth {
        SafeTransferLib.safeApprove(token, spender, 0);
        emit Approve(token, spender, 0);
    }

    /// @inheritdoc IEscrow
    function unapprove(address token, uint256 tokenId, address spender) external auth {
        if (tokenId == 0) {
            SafeTransferLib.safeApprove(token, spender, 0);
            emit Approve(token, spender, 0);
        } else {
            IERC6909(token).approve(spender, tokenId, 0);
            emit Approve(token, tokenId, spender, 0);
        }
    }

    /// @inheritdoc IPerPoolEscrow
    function pendingDepositIncrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value)
        external
        override
        auth
    {
        uint256 newValue = pendingDeposit[poolId][scId][token][tokenId] + value;
        pendingDeposit[poolId][scId][token][tokenId] = newValue;

        emit PendingDeposit(token, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPerPoolEscrow
    function pendingDepositDecrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value)
        external
        override
        auth
    {
        require(pendingDeposit[poolId][scId][token][tokenId] >= value, InsufficientPendingDeposit());

        uint256 newValue = pendingDeposit[poolId][scId][token][tokenId] - value;
        pendingDeposit[poolId][scId][token][tokenId] = newValue;

        emit PendingDeposit(token, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPerPoolEscrow
    function deposit(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value)
        external
        override
        auth
    {
        require(pendingDeposit[poolId][scId][token][tokenId] >= value, InsufficientPendingDeposit());

        uint256 prevholding = holding[poolId][scId][token][tokenId];
        if (tokenId == 0) {
            uint256 curholding = IERC20(token).balanceOf(address(this));
            require(curholding >= prevholding + value, InsufficientDeposit());
        } else {
            uint256 curholding = IERC6909(token).balanceOf(address(this), tokenId);
            require(curholding >= prevholding + value, InsufficientDeposit());
        }

        pendingDeposit[poolId][scId][token][tokenId] -= value;
        holding[poolId][scId][token][tokenId] += value;

        emit Deposit(token, tokenId, poolId, scId, value);
    }

    /// @inheritdoc IPerPoolEscrow
    function reserveIncrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value)
        external
        override
        auth
    {
        uint256 newValue = reservedAmount[poolId][scId][token][tokenId] + value;
        reservedAmount[poolId][scId][token][tokenId] = newValue;

        emit Reserve(token, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPerPoolEscrow
    function reserveDecrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value)
        external
        override
        auth
    {
        require(reservedAmount[poolId][scId][token][tokenId] >= value, InsufficientReservedAmount());

        uint256 newValue = reservedAmount[poolId][scId][token][tokenId] - value;
        reservedAmount[poolId][scId][token][tokenId] = newValue;

        emit Reserve(token, tokenId, poolId, scId, newValue);
    }

    /// @inheritdoc IPerPoolEscrow
    function withdraw(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value) external auth {
        require(availableBalanceOf(token, tokenId, poolId, scId) >= value, InsufficientBalance());

        holding[poolId][scId][token][tokenId] -= value;

        emit Withdraw(token, tokenId, poolId, scId, value);
    }

    /// @inheritdoc IPerPoolEscrow
    function availableBalanceOf(address token, uint256 tokenId, uint64 poolId, bytes16 scId)
        public
        view
        override
        returns (uint256)
    {
        uint256 holding_ = holding[poolId][scId][token][tokenId];
        uint256 reservedAmount_ = reservedAmount[poolId][scId][token][tokenId];

        if (holding_ < reservedAmount_) {
            return 0;
        } else {
            return holding_ - reservedAmount_;
        }
    }
}
