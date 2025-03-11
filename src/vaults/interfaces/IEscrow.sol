// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IEscrow {
    // --- Events ---
    event Approve(address indexed token, address indexed spender, uint256 value);
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

interface IPerPoolEscrow {
    event PendingDeposit(
        address indexed token, uint256 indexed tokenId, uint64 indexed poolId, uint16 scId, uint256 value
    );
    event Deposit(address indexed token, uint256 indexed tokenId, uint64 indexed poolId, uint16 scId, uint256 value);
    event PendingWithdraw(
        address indexed token, uint256 indexed tokenId, uint64 indexed poolId, uint16 scId, uint256 value
    );
    event Withdraw(address indexed token, uint256 indexed tokenId, uint64 indexed poolId, uint16 scId, uint256 value);

    function pendingDepositIncrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external;

    function pendingDepositDecrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external;

    function deposit(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value) external;

    function pendingWithdrawIncrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external;

    function pendingWithdrawDecrease(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value)
        external;

    function withdraw(address token, uint256 tokenId, uint64 poolId, uint16 scId, uint256 value) external;

    function availableBalanceOf(address token, uint256 tokenId, uint64 poolId, uint16 scId)
        external
        view
        returns (uint256);
}
