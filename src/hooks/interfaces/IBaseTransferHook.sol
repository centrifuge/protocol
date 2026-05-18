// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {IBalanceSheet} from "../../core/spoke/interfaces/IBalanceSheet.sol";
import {HookData, ITransferHook} from "../../core/spoke/interfaces/ITransferHook.sol";
import {IPoolEscrowProvider} from "../../core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import {IRoot} from "../../admin/interfaces/IRoot.sol";

/// @title  IBaseTransferHook
/// @notice Interface for base transfer hook with trusted call functionality
interface IBaseTransferHook is ITransferHook {
    //----------------------------------------------------------------------------------------------
    // Enums
    //----------------------------------------------------------------------------------------------

    enum TrustedCall {
        UpdateHookManager
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event UpdateHookManager(address indexed token, address indexed manager, bool canManage);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error UnknownTrustedCall();

    //----------------------------------------------------------------------------------------------
    // State variable getters
    //----------------------------------------------------------------------------------------------

    /// @notice Root authority that manages ward permissions and timelocked upgrades
    function root() external view returns (IRoot);

    /// @notice Spoke-side entry point, used to resolve escrow and balance sheet addresses
    function spoke() external view returns (ISpoke);

    /// @notice Pre-configured escrow address for single-pool hook deployments (address(0) if multi-pool)
    function poolEscrow() external view returns (address);

    /// @notice Address that originates cross-chain share transfers (BalanceSheet on this chain)
    function crosschainSource() external view returns (address);

    /// @notice Manages share token and asset balances, including minting, burning, and escrow transfers
    function balanceSheet() external view returns (IBalanceSheet);

    /// @notice Factory that maps pool IDs to escrow addresses for multi-pool hook deployments
    function poolEscrowProvider() external view returns (IPoolEscrowProvider);

    /// @notice Whether an address has manager permissions for a specific share token
    function manager(address token, address addr) external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Transfer type classification
    //----------------------------------------------------------------------------------------------

    /// @notice Whether the address is a pool escrow (checks both pre-configured and factory-deployed)
    function isPoolEscrow(address addr) external view returns (bool);

    /// @notice True when `from` is zero-address and `to` is not the pool escrow or cross-chain source (mint to user/vault)
    function isDepositRequestOrIssuance(address from, address to) external view returns (bool);

    /// @notice True when shares move from the pool escrow to the balance sheet (escrow → accounting)
    function isDepositFulfillment(address from, address to) external view returns (bool);

    /// @notice True when shares move from the balance sheet to a non-zero, non-escrow address (accounting → user)
    function isDepositClaim(address from, address to) external view returns (bool);

    /// @notice True when shares are burned from a non-zero address (user → zero-address)
    function isRedeemRequest(address from, address to) external pure returns (bool);

    /// @notice True when shares are minted to the pool escrow (zero-address → escrow, for fulfillment accounting)
    function isRedeemFulfillment(address from, address to) external view returns (bool);

    /// @notice True when shares are burned from a non-balance-sheet, non-cross-chain source (claim or cancel)
    function isRedeemClaimOrRevocation(address from, address to) external view returns (bool);

    /// @notice True when shares are burned by the cross-chain source (outbound cross-chain transfer)
    function isCrosschainTransfer(address from, address to) external view returns (bool);

    /// @notice True when shares are minted by the cross-chain source to a recipient (inbound cross-chain transfer)
    function isCrosschainTransferExecution(address from, address to) external view returns (bool);

    /// @notice Whether either the source or target address has the freeze bit set in hook data
    function isSourceOrTargetFrozen(address from, address to, HookData calldata hookData) external view returns (bool);

    /// @notice Whether the source address passes membership validation per hook data
    function isSourceMember(address from, HookData calldata hookData) external view returns (bool);

    /// @notice Whether the target address passes membership validation per hook data
    function isTargetMember(address to, HookData calldata hookData) external view returns (bool);
}
