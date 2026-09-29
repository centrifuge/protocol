// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpoke} from "../../../core/spoke/interfaces/ISpoke.sol";
import {IEscrowProvider} from "../../../core/spoke/factories/interfaces/IEscrowFactory.sol";

import {IRoot} from "../../../admin/interfaces/IRoot.sol";

import {HookData, ITransferHook} from "../../interfaces/ITransferHook.sol";

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
    error NotEnvoy();
    error UnexpectedValue();

    //----------------------------------------------------------------------------------------------
    // State variable getters
    //----------------------------------------------------------------------------------------------

    /// @notice Root authority that manages ward permissions and timelocked upgrades
    function root() external view returns (IRoot);

    /// @notice Address that originates cross-chain share transfers (SpokeHandler on this chain)
    function crosschainSource() external view returns (address);

    /// @notice Manages share token and asset balances, including minting, burning, and escrow transfers
    function spoke() external view returns (ISpoke);

    /// @notice Factory that maps pool IDs to escrow addresses
    function escrowProvider() external view returns (IEscrowProvider);

    /// @notice Whether an address has manager permissions for a specific share token
    function manager(address token, address addr) external view returns (bool);

    //----------------------------------------------------------------------------------------------
    // Transfer type classification
    //----------------------------------------------------------------------------------------------

    /// @notice Whether the address is a pool escrow deployed by the escrow factory
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

    /// @notice True when a holder's shares leave the pool: the burn-side check that gates a fulfilled
    ///         redemption or a cancelled-deposit refund, and the pair a ward burning a holder's balance
    ///         directly produces.
    /// @dev    The `maxRedeem`, `maxWithdraw` and `claimableCancelDepositRequest` views run it with the
    ///         holder as the source, but the claim paths run it against the receiver; only `redeem` also
    ///         gates on the controller, through `maxRedeem`. A zero view is therefore not proof that no
    ///         authorized claim to another receiver is available.
    function isRedeemClaimOrRevocation(address from, address to) external view returns (bool);

    /// @notice True when the destination is a chain rather than a holder, for an outbound cross-chain
    ///         transfer. {ShareTokenRegistrar.canBridge} encodes the destination centrifuge id as an
    ///         address and runs that pair through the restriction check, which is the encoding this
    ///         matches; a registrar that answers `canBridge` some other way never produces the pair.
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
