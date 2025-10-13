// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

interface ISafe {
    /// @notice Checks if an address is an owner of the safe
    /// @param signer The address to check for ownership
    /// @return True if the address is an owner, false otherwise
    function isOwner(address signer) external view returns (bool);
}
