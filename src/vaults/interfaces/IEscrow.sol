// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title  Escrow for holding tokens
interface IEscrow {
    // --- Events ---
    /// @notice Emitted when an approval is made
    /// @param token The address of the token
    /// @param spender The address of the spender
    /// @param value The new total allowance
    event Approve(address indexed token, address indexed spender, uint256 value);

    /// @notice Emitted when an approval is made
    /// @param token The address of the token
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param spender The address of the spender
    /// @param value The new total allowance
    event Approve(address indexed token, uint256 indexed tokenId, address indexed spender, uint256 value);

    // --- Token approvals ---
    /// @notice sets the allowance of `spender` to `type(uint256).max` if it is currently 0
    function approveMax(address token, uint256 tokenId, address spender) external;

    /// @notice sets the allowance of `spender` to `type(uint256).max` if it is currently 0
    function approveMax(address token, address spender) external;

    /// @notice sets the allowance of `spender` to 0
    function unapprove(address token, uint256 tokenId, address spender) external;

    /// @notice sets the allowance of `spender` to 0
    function unapprove(address token, address spender) external;
}

/// @title PerPoolEscrow separating funds by pool and share class
interface IPerPoolEscrow {
    // --- Events ---
    /// @notice Emitted when a deposit will be made in the future
    /// @param token The address of the to be deposited token
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount to be deposited
    event PendingDeposit(
        address indexed token, uint256 indexed tokenId, uint64 indexed poolId, bytes16 scId, uint256 value
    );

    /// @notice Emitted when a deposit is made
    /// @param token The address of the deposited token
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount deposited
    event Deposit(address indexed token, uint256 indexed tokenId, uint64 indexed poolId, bytes16 scId, uint256 value);

    /// @notice Emitted when an amount is reserved
    /// @param token The address of the reserved token
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount reserved
    event Reserve(address indexed token, uint256 indexed tokenId, uint64 indexed poolId, bytes16 scId, uint256 value);

    /// @notice Emitted when a withdraw is made
    /// @param token The address of the withdrawn token
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount withdrawn
    event Withdraw(address indexed token, uint256 indexed tokenId, uint64 indexed poolId, bytes16 scId, uint256 value);

    // --- Errors ---
    /// @notice Dispatched when pending deposits are insufficient
    error InsufficientPendingDeposit();

    /// @notice Dispatched when the balance of the escrow did not increase sufficiently
    error InsufficientDeposit();

    /// @notice Dispatched when the the outstanding reserved amount is insufficient for the decrease
    error InsufficientReservedAmount();

    /// @notice Dispatched when the balance of the escrow is insufficient for the withdrawal
    error InsufficientBalance();

    // --- Functions ---
    /// @notice Increases the pending deposit of `value` for `token` in `poolId` and `scId`
    /// @dev MUST be made prior to calling `deposit`
    /// @param token The address of the token to be deposited
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount to increase
    function pendingDepositIncrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value)
        external;

    /// @notice Decreases the pending deposit of `value` for `token` in `poolId` and `scId`
    /// @dev MUST fail if `value` is greater than the current pending deposit
    /// @param token The address of the token to be deposited
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount to decrease
    function pendingDepositDecrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value)
        external;

    /// @notice Deposits `value` of `token` in `poolId` and `scId`
    /// @dev MUST be made after calling `pendingDepositIncrease`. Fails if `value` is greater than the current pending
    /// deposit
    /// @param token The address of the token to be deposited
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount to deposit
    function deposit(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value) external;

    /// @notice Increases the reserved amount of `value` for `token` in `poolId` and `scId`
    /// @dev MUST prevent the reserved amount from being withdrawn
    /// @param token The address of the token to be reserved
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount to reserve
    function reserveIncrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value) external;

    /// @notice Decreases the reserved amount of `value` for `token` in `poolId` and `scId`
    /// @dev MUST fail if `value` is greater than the current reserved amount
    /// @param token The address of the token to be reserved
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount to decrease
    function reserveDecrease(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value) external;

    /// @notice Withdraws `value` of `token` in `poolId` and `scId`
    /// @dev MUST ensure that reserved amounts are not withdrawn
    /// @param token The address of the token to be withdrawn
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @param value The amount to withdraw
    function withdraw(address token, uint256 tokenId, uint64 poolId, bytes16 scId, uint256 value) external;

    /// @notice Provides the available balance of `token` in `poolId` and `scId`
    /// @dev MUST return the balance minus the reserved amount
    /// @param token The address of the token to be checked
    /// @param tokenId The id of the token - 0 for ERC20
    /// @param poolId The id of the pool
    /// @param scId The id of the share class
    /// @return The available balance
    function availableBalanceOf(address token, uint256 tokenId, uint64 poolId, bytes16 scId)
        external
        view
        returns (uint256);
}
