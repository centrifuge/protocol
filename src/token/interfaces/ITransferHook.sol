// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IERC165} from "../../misc/interfaces/IERC7575.sol";

struct HookData {
    bytes16 from;
    bytes16 to;
}

uint8 constant SUCCESS_CODE_ID = 0;
string constant SUCCESS_MESSAGE = "transfer-allowed";

uint8 constant ERROR_CODE_ID = 1;
string constant ERROR_MESSAGE = "transfer-blocked";

/// @notice Hook interface to customize share token behaviour
/// @dev    To detect specific system actions:
///           Issuance:                         address(0)       -> address(user)
///           Deposit fulfillment:              address(0)       -> escrow
///           Deposit claim:                    escrow       -> address(user)
///           Redeem fulfillment:               spoke            -> address(0)
///           Direct burn of a holder:          address(user)    -> address(0)
///           Cross-chain transfer:             address(user)    -> address(uint160(chainId))
///           Cross-chain execution:            crosschainSource -> address(user)
///
///         Vault requests, redeem claims and request transfers have no enforced share leg; the vault asks
///         the hook for them through `IRoleHook` role checks instead.
///
///         Endorsed refers to core protocol contracts, which can be retrieved using root.endorsed(addr)
///         escrow: Pool-specific escrow contract identified via escrowFactory.poolId(addr)
///         spoke: Contract that fulfills redemptions
///         crosschainSource: Contract handling cross-chain message execution (SpokeHandler)
interface ITransferHook is IERC165 {
    //----------------------------------------------------------------------------------------------
    // Errors
    //----------------------------------------------------------------------------------------------

    error TransferBlocked();
    error InvalidUpdate();

    //----------------------------------------------------------------------------------------------
    // Callbacks
    //----------------------------------------------------------------------------------------------

    /// @notice Callback on standard ERC20 transfer.
    /// @dev    MUST return bytes4(keccak256("onERC20Transfer(address,address,uint256,(bytes16,bytes16))"))
    ///         if successful. The token calls it after it moved the shares, so balances read here already include
    ///         `value`; `checkERC20Transfer`, asked through the token's `checkTransferRestriction`, runs before.
    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookdata)
        external
        returns (bytes4);

    /// @notice Callback on authorized ERC20 transfer.
    /// @dev    Cannot be blocked, can only be used to update state.
    ///         Return value is ignored, only kept for compatibility with V2 share tokens.
    function onERC20AuthTransfer(address sender, address from, address to, uint256 value, HookData calldata hookdata)
        external
        returns (bytes4);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Check if given transfer can be performed
    function checkERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        external
        view
        returns (bool);

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Update a set of restriction for a token
    /// @dev    MAY be user specific, which would be included in the encoded `update` value
    function updateRestriction(address token, bytes memory update) external;
}
