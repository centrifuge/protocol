// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ERC20} from "src/misc/ERC20.sol";
import {IDelegationToken, Delegation, Signature} from "src/cfg/interfaces/IDelegationToken.sol";

/// @title  Delegation Token
/// @notice Extension of ERC20 to support token delegation
///         This extension keeps track of the current voting power delegated to each account. Voting power can be
///         delegated either by calling the `delegate` function directly, or by providing a signature to be
///         used with `delegateBySig`.
///
///         This enables onchain votes on external voting smart contracts leveraging storage proofs.
///
///         By default, token balance does not account for voting power. This makes transfers cheaper. Whether
///         an account has to self-delegate to vote depends on the voting contract implementation.
/// @author Modified from https://github.com/morpho-org/morpho-token-upgradeable
contract DelegationToken is ERC20, IDelegationToken {
    bytes32 internal constant DELEGATION_TYPEHASH =
        keccak256("Delegation(address delegatee,uint256 nonce,uint256 expiry)");

    /// @inheritdoc IDelegationToken
    mapping(address => address) public delegatee;
    /// @inheritdoc IDelegationToken
    mapping(address => uint256) public delegatedVotingPower;
    /// @inheritdoc IDelegationToken
    mapping(address => uint256) public delegationNonce;

    constructor(uint8 decimals_) ERC20(decimals_) {}

    /// @inheritdoc IDelegationToken
    function delegate(address newDelegatee) external {
        address delegator = msg.sender;
        _delegate(delegator, newDelegatee);
    }

    /// @inheritdoc IDelegationToken
    function delegateWithSig(Delegation calldata delegation, Signature calldata signature) external {
        require(block.timestamp <= delegation.expiry, DelegatesExpiredSignature());

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR(), keccak256(abi.encode(DELEGATION_TYPEHASH, delegation)))
        );
        address delegator = ecrecover(digest, signature.v, signature.r, signature.s);
        require(delegation.nonce == delegationNonce[delegator]++, InvalidDelegationNonce());

        _delegate(delegator, delegation.delegatee);
    }

    /// @dev Delegates the balance of the `delegator` to `newDelegatee`.
    function _delegate(address delegator, address newDelegatee) internal {
        address oldDelegatee = delegatee[delegator];
        delegatee[delegator] = newDelegatee;

        emit DelegateeChanged(delegator, oldDelegatee, newDelegatee);
        _moveDelegateVotes(oldDelegatee, newDelegatee, balanceOf(delegator));
    }

    /// @dev Moves voting power when tokens are transferred.
    function transfer(address to, uint256 value) public override(ERC20) returns (bool success) {
        success = super.transfer(to, value);
        _moveDelegateVotes(delegatee[msg.sender], delegatee[to], value);
    }

    /// @dev Moves voting power when tokens are transferred.
    function transferFrom(address from, address to, uint256 value) public override(ERC20) returns (bool success) {
        success = super.transferFrom(from, to, value);
        _moveDelegateVotes(delegatee[from], delegatee[to], value);
    }

    /// @dev Adds voting power when tokens are minted.
    function mint(address to, uint256 value) public override(ERC20) {
        super.mint(to, value);
        _moveDelegateVotes(address(0), delegatee[to], value);
    }

    /// @dev Removes voting power when tokens are burned.
    function burn(address from, uint256 value) public override(ERC20) {
        super.burn(from, value);
        _moveDelegateVotes(delegatee[from], address(0), value);
    }

    /// @dev Moves delegated votes from one delegate to another.
    function _moveDelegateVotes(address from, address to, uint256 amount) internal {
        if (from != to && amount > 0) {
            if (from != address(0)) {
                uint256 oldValue = delegatedVotingPower[from];
                uint256 newValue = oldValue - amount;
                delegatedVotingPower[from] = newValue;
                emit DelegatedVotingPowerChanged(from, oldValue, newValue);
            }
            if (to != address(0)) {
                uint256 oldValue = delegatedVotingPower[to];
                uint256 newValue = oldValue + amount;
                delegatedVotingPower[to] = newValue;
                emit DelegatedVotingPowerChanged(to, oldValue, newValue);
            }
        }
    }
}
