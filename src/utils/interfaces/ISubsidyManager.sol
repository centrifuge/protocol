// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../core/types/PoolId.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

interface ISubsidyManager is ITrustedContractUpdate {
    event File(bytes32 indexed what, address data);
    event DepositSubsidy(PoolId indexed poolId, address indexed sender, uint256 amount);
    event WithdrawSubsidy(PoolId indexed poolId, address indexed sender, uint256 amount);

    error FileUnrecognizedParam();
    error RefundEscrowNotDeployed();
    error NotEnoughToWithdraw();

    /// @notice Updates contract parameters of type address.
    /// @param what The bytes32 representation of 'refundEscrowFactory'.
    /// @param data The new contract address.
    function file(bytes32 what, address data) external;

    /// @notice Deposit funds to subsidy vault actions through the gateway
    function deposit(PoolId poolId) external payable;

    /// @notice Withdraw subsidized funds to an account
    function withdraw(PoolId poolId, address to, uint256 value) external;

    /// @notice Withdraws all subsidized funds to an account for cross-chain message payment.
    /// @dev Unlike `withdraw()`, this function does not emit a `WithdrawSubsidy` event because
    ///      it is used as a utility to temporarily withdraw funds for
    ///      paying cross-chain messages. The excess funds are refunded back to the RefundEscrow
    ///      in the same transaction (or asynchronously shortly after), so no actual withdrawal
    ///      from the subsidy system occurs.
    /// @param poolId The pool whose subsidy escrow to withdraw from.
    /// @param to The address to send the funds to (typically the caller for message payment).
    /// @return The escrow address from where the subsidy is withdrawn.
    /// @return amount The amount withdrawn.
    function withdrawAll(PoolId poolId, address to) external returns (address, uint256 amount);
}
