// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {ISpoke} from "../../../core/spoke/interfaces/ISpoke.sol";
import {IEscrowProvider} from "../../../core/spoke/factories/interfaces/IEscrowFactory.sol";

import {IRoot} from "../../../admin/interfaces/IRoot.sol";

import {IRoleHook} from "../../interfaces/IRoleHook.sol";
import {ITransferHook} from "../../interfaces/ITransferHook.sol";

/// @title  IShareTokenHook
/// @notice Interface for the base restriction hook: real ERC20 legs arrive via `ITransferHook`, and the role checks
///         of value that moves without one via `IRoleHook`.
interface IShareTokenHook is ITransferHook, IRoleHook {
    //----------------------------------------------------------------------------------------------
    // Enums
    //----------------------------------------------------------------------------------------------

    enum TrustedCall {
        UpdateHookManager
    }

    /// @notice What a share movement is, read off its endpoints in this order of precedence.
    enum Kind {
        /// @dev A mint to a holder, including a vault's instant issuance
        Mint,
        /// @dev Shares leaving an escrow for a holder: the delivery of a deposit claim
        Release,
        /// @dev The spoke burning the shares it holds: the revocation of redeemed shares
        Fulfill,
        /// @dev A holder's shares burned directly, which no vault path does: what a ward burning a balance produces
        Burn,
        /// @dev Every other movement, including a mint into an escrow and the cross-chain sends and receipts
        Transfer
    }

    //----------------------------------------------------------------------------------------------
    // Events
    //----------------------------------------------------------------------------------------------

    event UpdateHookManager(address indexed token, address indexed manager, bool canManage);

    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error InvalidInputs();
    error InvalidHookBit();
    error UnknownTrustedCall();
    error NotEnvoy();
    error UnexpectedValue();
    error VaultCannotBeFrozen();
    error ShareTokenDoesNotExist();

    //----------------------------------------------------------------------------------------------
    // State variable getters
    //----------------------------------------------------------------------------------------------

    /// @notice The bit of a user's hook data that marks the account frozen. The hook data is laid out as the
    ///         memberlist valid-until timestamp in the high 64 bits, this bit at position 0, and bits 1 to 63 free for
    ///         a hook that stores more per investor. `updateMember`, `freeze` and `unfreeze` change only the bits they
    ///         own.
    function FREEZE_BIT() external view returns (uint8);

    /// @notice The flavor this hook was deployed as: the mask of roles that ask for membership, beyond not being
    ///         frozen, as set out in `HookPolicies`. Both the transfer check and the role check follow it, so the two
    ///         cannot disagree about who may do what.
    function policy() external view returns (uint8);

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
    // Classification
    //----------------------------------------------------------------------------------------------

    /// @notice The kind of a movement of shares from `from` to `to`
    function leg(address from, address to) external view returns (Kind);

    /// @notice Whether the address is an escrow deployed by the escrow factory
    function isEscrow(address addr) external view returns (bool);

    /// @notice Whether `addr` is a linked vault whose registered pool and share class issue `token`. Such a
    ///         vault holds shares mid-revocation on every redemption, so it cannot be frozen. A vault of
    ///         another share class, including another pool's, is an ordinary account for `token`.
    function isShareClassVault(address token, address addr) external view returns (bool);
}
