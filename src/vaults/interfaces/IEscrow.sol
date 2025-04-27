// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

import {IRecoverable} from "src/misc/Recoverable.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

/// @title  Escrow for holding assets
interface IEscrow {
    // --- Events ---
    /// @notice Emitted when an authTransferTo is made
    /// @dev Needed as allowances increase attack surface
    event AuthTransferTo(address indexed asset, uint256 indexed tokenId, address reciver, uint256 value);

    /// @notice Emitted when the escrow has insufficient balance for an action - virtual or actual balance
    error InsufficientBalance(address asset, uint256 tokenId, uint256 value, uint256 balance);

    /// @notice
    function authTransferTo(address asset, uint256 tokenId, address receiver, uint256 value) external;

    /// @notice
    function authTransferTo(address asset, address receiver, uint256 value) external;
}

struct Holding {
    uint128 total;
    uint128 reserved;
}

/// @title PerPoolEscrow separating funds by pool and share class
interface IPoolEscrow is IEscrow, IRecoverable {
    // --- Events ---
    /// @notice Emitted when a deposit is made
    /// @param asset The address of the deposited asset
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount deposited
    event Deposit(
        address indexed asset, uint256 indexed tokenId, PoolId indexed poolId, ShareClassId scId, uint128 value
    );

    /// @notice Emitted when an amount is reserved
    /// @param asset The address of the reserved asset
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The delta amount reserved
    /// @param value The new absolute amount reserved
    event IncreaseReserve(
        address indexed asset,
        uint256 indexed tokenId,
        PoolId indexed poolId,
        ShareClassId scId,
        uint256 delta,
        uint128 value
    );

    /// @notice Emitted when an amount is unreserved
    /// @param asset The address of the reserved asset
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The delta amount unreserved
    /// @param value The new absolute amount reserved
    event DecreaseReserve(
        address indexed asset,
        uint256 indexed tokenId,
        PoolId indexed poolId,
        ShareClassId scId,
        uint256 delta,
        uint128 value
    );

    /// @notice Emitted when a withdraw is made
    /// @param asset The address of the withdrawn asset
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount withdrawn
    event Withdraw(
        address indexed asset, uint256 indexed tokenId, PoolId indexed poolId, ShareClassId scId, uint128 value
    );

    // --- Errors ---
    /// @notice Dispatched when the balance of the escrow did not increase sufficiently
    error InsufficientDeposit();

    /// @notice Dispatched when the outstanding reserved amount is insufficient for the decrease
    error InsufficientReservedAmount();

    // --- Functions ---
    /// @notice Deposits `value` of `asset` in underlying `poolId` and given `scId`
    ///
    /// @dev NOTE: Must ensure balance sufficiency, i.e. that the depositing amount does not exceed the balance of
    /// escrow
    ///
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be deposited
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param value The amount to deposit
    function deposit(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external;

    /// @notice Withdraws `value` of `asset` in underlying `poolId` and given `scId`
    /// @dev MUST ensure that reserved amounts are not withdrawn
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be withdrawn
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param value The amount to withdraw
    function withdraw(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external;

    /// @notice Increases the reserved amount of `value` for `asset` in underlying `poolId` and given `scId`
    /// @dev MUST prevent the reserved amount from being withdrawn
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be reserved
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param value The amount to reserve
    function reserveIncrease(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external;

    /// @notice Decreases the reserved amount of `value` for `asset` in underlying `poolId` and given `scId`
    /// @dev MUST fail if `value` is greater than the current reserved amount
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be reserved
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param value The amount to decrease
    function reserveDecrease(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external;

    /// @notice Provides the available balance of `asset` in underlying `poolId` and given `scId`
    /// @dev MUST return the balance minus the reserved amount
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be checked
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @return The available balance
    function availableBalanceOf(ShareClassId scId, address asset, uint256 tokenId) external view returns (uint128);
}
