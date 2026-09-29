// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Holding, IEscrow} from "./interfaces/IEscrow.sol";

import {Auth} from "../../misc/Auth.sol";
import {Recoverable} from "../../misc/Recoverable.sol";
import {IERC20} from "../../misc/interfaces/IERC20.sol";
import {SafeTransferLib} from "../../misc/libraries/SafeTransferLib.sol";
import {IERC6909, TransferFailed} from "../../misc/interfaces/IERC6909.sol";

import {PoolId} from "../types/PoolId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";

/// @title  Escrow
/// @notice Escrow contract that holds assets for a specific pool separated by share classes.
contract Escrow is Auth, Recoverable, IEscrow {
    PoolId public immutable poolId;

    mapping(ShareClassId => mapping(address asset => mapping(uint256 tokenId => Holding))) public holding;
    mapping(
        ShareClassId
            => mapping(
            address reserver => mapping(bytes32 reason => mapping(address asset => mapping(uint256 tokenId => uint128)))
        )
    ) public reservedBy;

    constructor(PoolId poolId_, address deployer) Auth(deployer) {
        poolId = poolId_;
    }

    /// @inheritdoc IEscrow
    function deposit(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external auth {
        holding[scId][asset][tokenId].total += value;

        emit Deposit(asset, tokenId, poolId, scId, value);
    }

    /// @inheritdoc IEscrow
    function withdraw(ShareClassId scId, address asset, uint256 tokenId, address receiver, uint128 value)
        external
        auth
    {
        Holding storage holding_ = holding[scId][asset][tokenId];
        require(holding_.total >= holding_.reserved, InsufficientBalance(asset, tokenId, value, 0));

        uint128 balance = holding_.total - holding_.reserved;
        require(balance >= value, InsufficientBalance(asset, tokenId, value, balance));

        holding_.total -= value;
        emit Withdraw(asset, tokenId, poolId, scId, receiver, value);
    }

    /// @inheritdoc IEscrow
    function reserve(ShareClassId scId, address asset, uint256 tokenId, uint128 value, address caller, bytes32 reason)
        external
        auth
    {
        Holding storage holding_ = holding[scId][asset][tokenId];

        uint128 newReservedAmount = reservedBy[scId][caller][reason][asset][tokenId] + value;
        reservedBy[scId][caller][reason][asset][tokenId] = newReservedAmount;
        holding_.reserved += value;

        emit IncreaseReserve(asset, tokenId, poolId, scId, caller, reason, value, newReservedAmount);
    }

    /// @inheritdoc IEscrow
    function unreserve(ShareClassId scId, address asset, uint256 tokenId, uint128 value, address caller, bytes32 reason)
        external
        auth
    {
        Holding storage holding_ = holding[scId][asset][tokenId];

        uint128 currentReserved = reservedBy[scId][caller][reason][asset][tokenId];
        require(currentReserved >= value, InsufficientReserve());

        uint128 newReservedAmount = currentReserved - value;
        reservedBy[scId][caller][reason][asset][tokenId] = newReservedAmount;
        holding_.reserved -= value;

        emit DecreaseReserve(asset, tokenId, poolId, scId, caller, reason, value, newReservedAmount);
    }

    /// @inheritdoc IEscrow
    function authTransferTo(address asset, uint256 tokenId, address receiver, uint256 amount) external auth {
        if (tokenId == 0) {
            uint256 balance = IERC20(asset).balanceOf(address(this));
            require(balance >= amount, InsufficientBalance(asset, tokenId, amount, balance));

            SafeTransferLib.safeTransfer(asset, receiver, amount);
        } else {
            uint256 balance = IERC6909(asset).balanceOf(address(this), tokenId);
            require(balance >= amount, InsufficientBalance(asset, tokenId, amount, balance));

            require(IERC6909(asset).transfer(receiver, tokenId, amount), TransferFailed());
        }

        emit AuthTransferTo(asset, tokenId, receiver, amount);
    }

    /// @inheritdoc IEscrow
    function availableBalanceOf(ShareClassId scId, address asset, uint256 tokenId) public view returns (uint128) {
        Holding storage holding_ = holding[scId][asset][tokenId];
        if (holding_.total < holding_.reserved) return 0;
        return holding_.total - holding_.reserved;
    }
}
