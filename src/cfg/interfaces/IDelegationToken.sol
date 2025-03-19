// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

struct Delegation {
    address delegatee;
    uint256 nonce;
    uint256 expiry;
}

struct Signature {
    uint8 v;
    bytes32 r;
    bytes32 s;
}

interface IDelegationToken {
    /// @notice Emitted when an delegator changes their delegatee.
    event DelegateeChanged(address indexed delegator, address indexed oldDelegatee, address indexed newDelegatee);

    /// @notice Emitted when a delegatee's delegated voting power changes.
    event DelegatedVotingPowerChanged(address indexed delegatee, uint256 oldVotes, uint256 newVotes);

    /// @notice The signature used has expired.
    error DelegatesExpiredSignature();

    /// @notice The delegation nonce used by the signer is not its current delegation nonce.
    error InvalidDelegationNonce();

    /// @notice Returns the delegatee that `account` has chosen.
    function delegatee(address account) external view returns (address);

    /// @notice Returns the current voting power delegated to `account`.
    function delegatedVotingPower(address account) external view returns (uint256);

    /// @notice Returns the current delegation nonce of `account`.
    function delegationNonce(address account) external view returns (uint256);

    /// @notice Delegates the balance of the sender to `newDelegatee`.
    /// @dev Delegating to the zero address effectively removes the delegation, incidentally making transfers cheaper.
    /// @dev Delegating to the previous delegatee does not revert.
    function delegate(address newDelegatee) external;

    /// @notice Delegates the balance of the signer to `newDelegatee`.
    /// @dev Delegating to the zero address effectively removes the delegation, incidentally making transfers cheaper.
    /// @dev Delegating to the previous delegatee effectively revokes past signatures with the same nonce.
    function delegateWithSig(Delegation calldata delegation, Signature calldata signature) external;
}
