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
    mapping(uint64 poolId => mapping(uint16 scId => mapping(address token => mapping(uint256 tokenId => uint256))))
        internal pendingWithdraws;
    mapping(uint64 poolId => mapping(uint16 scId => mapping(address token => mapping(uint256 tokenId => uint256))))
        internal pendingDeposits;
    mapping(uint64 poolId => mapping(uint16 scId => mapping(address token => mapping(uint256 tokenId => uint256))))
        internal holdings;

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

    function pendingDepositIncrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external
        override
        auth
    {
        pendingDeposits[poolId][scId][token][tokenId] += value;
    }

    function pendingDepositDecrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external
        override
        auth
    {
        require(pendingDeposits[poolId][scId][token][tokenId] >= value, "Escrow/insufficient-pending-deposits");

        pendingDeposits[poolId][scId][token][tokenId] -= value;
    }

    function deposit(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external
        override
        auth
    {
        require(pendingDeposits[poolId][scId][token][tokenId] >= value, "Escrow/insufficient-pending-deposits");

        uint256 prevHoldings = holdings[poolId][scId][token][tokenId];
        if (tokenId == 0) {
            uint256 curHoldings = IERC20(token).balanceOf(address(this));
            require(curHoldings >= prevHoldings + value, "Escrow/insufficient-balance-increase");
        } else {
            uint256 curHoldings = IERC6909(token).balanceOf(address(this), tokenId);
            require(curHoldings >= prevHoldings + value, "Escrow/insufficient-balance-increase");
        }

        pendingDeposits[poolId][scId][token][tokenId] -= value;
        holdings[poolId][scId][token][tokenId] += value;
    }

    function pendingWithdrawIncrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external
        override
        auth
    {
        pendingWithdraws[poolId][scId][token][tokenId] += value;
    }

    function pendingWithdrawDecrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external
        override
        auth
    {
        require(pendingWithdraws[poolId][scId][token][tokenId] >= value, "Escrow/insufficient-pending-withdraws");

        pendingWithdraws[poolId][scId][token][tokenId] -= value;
    }

    function withdraw(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value) external auth {
        require(availableBalanceOf(token, tokenId, poolId, scId) > value, "Escrow/insufficient-funds");

        holdings[poolId][scId][token][tokenId] -= value;
    }

    function availableBalanceOf(address token, uint256 tokenId, uint64 poolId, uint16 scId)
        public
        view
        override
        returns (uint256)
    {
        uint256 holdings_ = holdings[poolId][scId][token][tokenId];
        uint256 pendingWithdraws_ = pendingWithdraws[poolId][scId][token][tokenId];

        if (holdings_ < pendingWithdraws_) {
            return 0;
        } else {
            return holdings_ - pendingWithdraws_;
        }
    }
}
