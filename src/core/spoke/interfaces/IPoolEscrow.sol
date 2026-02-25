// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRecoverable} from "../../../misc/Recoverable.sol";
import {IEscrow} from "../../../misc/interfaces/IEscrow.sol";

import {PoolId} from "../../types/PoolId.sol";
import {ShareClassId} from "../../types/ShareClassId.sol";

struct Holding {
    uint128 total;
    uint128 reserved;
}

/// @title Per-Pool Escrow separating funds by pool and share class
interface IPoolEscrow is IEscrow, IRecoverable {
    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

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
    /// @param caller The address of the manager creating the reservation
    /// @param reason The reason code for the reservation
    /// @param delta The delta amount reserved
    /// @param value The new absolute amount reserved
    event IncreaseReserve(
        address indexed asset,
        uint256 indexed tokenId,
        PoolId indexed poolId,
        ShareClassId scId,
        address caller,
        uint32 reason,
        uint128 delta,
        uint128 value
    );

    /// @notice Emitted when an amount is unreserved
    /// @param asset The address of the reserved asset
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param caller The address of the manager that created the reservation
    /// @param reason The reason code that was used when reserving
    /// @param delta The delta amount unreserved
    /// @param value The new absolute amount reserved
    event DecreaseReserve(
        address indexed asset,
        uint256 indexed tokenId,
        PoolId indexed poolId,
        ShareClassId scId,
        address caller,
        uint32 reason,
        uint128 delta,
        uint128 value
    );

    /// @notice Emitted when a withdraw is made
    /// @param asset The address of the withdrawn asset
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param receiver The address receiving the withdrawn assets
    /// @param value The amount withdrawn
    event Withdraw(
        address indexed asset,
        uint256 indexed tokenId,
        PoolId indexed poolId,
        ShareClassId scId,
        address receiver,
        uint128 value
    );

    /// @notice Emitted when ETH is transferred to the escrow
    /// @param who The address that sent the ETH
    /// @param amount The amount transferred
    event ReceiveNativeTokens(address who, uint256 amount);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    /// @notice Dispatched when the balance of the escrow did not increase sufficiently
    error InsufficientDeposit();

    /// @notice Dispatched when the outstanding reserved amount is insufficient for the decrease
    error InsufficientReserve();

    //----------------------------------------------------------------------------------------------
    // Functions
    //----------------------------------------------------------------------------------------------

    /// @notice Deposits `value` of `asset` in underlying `poolId` and given `scId`
    /// @dev NOTE: Must ensure balance sufficiency, i.e. that the depositing amount does not exceed the balance of escrow
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be deposited
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param value The amount to deposit
    function deposit(ShareClassId scId, address asset, uint256 tokenId, uint128 value) external;

    /// @notice Withdraws `value` of `asset` in underlying `poolId` and given `scId`
    /// @dev If wasNoted is true, funds were already added to 'total' (decrements total and emits event)
    ///      If wasNoted is false, funds are in 'reserved' only (just transfers, no accounting change)
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be withdrawn
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param receiver The address receiving the withdrawn assets
    /// @param value The amount to withdraw
    function withdraw(ShareClassId scId, address asset, uint256 tokenId, address receiver, uint128 value) external;

    /// @notice Increases the reserved amount of `value` for `asset` in underlying `poolId` and given `scId`
    /// @dev Reserves funds in a specific bucket identified by caller and reason
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be reserved
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param value The amount to reserve
    /// @param caller The address of the manager creating the reservation (passed by BalanceSheet)
    /// @param reason The reason code (1=DEPOSIT, 2=REDEEM)
    function reserve(ShareClassId scId, address asset, uint256 tokenId, uint128 value, address caller, uint32 reason)
        external;

    /// @notice Decreases the reserved amount of `value` for `asset` in underlying `poolId` and given `scId`
    /// @dev Unreserves funds from a specific bucket. MUST fail if bucket has insufficient funds.
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be unreserved
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @param value The amount to decrease
    /// @param caller The address of the manager that created the reservation
    /// @param reason The reason code that was used when reserving
    function unreserve(ShareClassId scId, address asset, uint256 tokenId, uint128 value, address caller, uint32 reason)
        external;

    /// @notice Provides the available balance of `asset` in underlying `poolId` and given `scId`
    /// @dev MUST return the balance minus the reserved amount
    /// @param scId The id of the share class
    /// @param asset The address of the asset to be checked
    /// @param tokenId The id of the asset - 0 for ERC20
    /// @return The available balance
    function availableBalanceOf(ShareClassId scId, address asset, uint256 tokenId) external view returns (uint128);
}
