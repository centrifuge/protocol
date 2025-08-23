// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface ILockup {
    // --- Events ---
    event UpdateLastDepositClaim(address indexed token, address indexed user, uint32 lastDepositClaim);

    // --- Storing last deposit claim ---
    function updateLastDepositClaim(address token, address user) external;
}
