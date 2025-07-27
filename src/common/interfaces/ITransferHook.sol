// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC165} from "../../misc/interfaces/IERC7575.sol";

struct HookData {
    bytes16 from;
    bytes16 to;
}

uint8 constant SUCCESS_CODE_ID = 0;
string constant SUCCESS_MESSAGE = "transfer-allowed";

uint8 constant ERROR_CODE_ID = 1;
string constant ERROR_MESSAGE = "transfer-blocked";

/// @dev Magic address denoting a transfer to the escrow
/// @dev Solely used for gas saving since escrow is per pool
/// @dev Equals 118_624 such that there is no collision with any uint16 Centrifuge ID
address constant ESCROW_HOOK_ID = address(uint160(0x1CF60));

/// @notice Hook interface to customize share token behaviour
/// @dev    To detect specific system actions:
///           Deposit request:                  address(0)      -> address(user)
///           Deposit request fulfillment:       address(0)      -> Endorsed
///           Deposit or cancel redeem claim:   Endorsed        -> address(user)
///           Redeem request:                   address(user)   -> ESCROW_HOOK_ID
///           Redeem request fulfillment:        Endorsed        -> address(0)
///           Redeem or cancel deposit claim:   address(user)   -> address(0)
///           Cross-chain transfer check:       address(user)   -> address(uint160(chainId))
///           Cross-chain transfer execution:   address(spoke)  -> address(0)
///
///         Endorsed refers to core protocol contracts, which can be retrieved using root.endorsed(addr)
interface ITransferHook is IERC165 {
    // --- Errors ---
    error TransferBlocked();
    error InvalidUpdate();

    /// @notice Callback on standard ERC20 transfer.
    /// @dev    MUST return bytes4(keccak256("onERC20Transfer(address,address,uint256,(bytes16,bytes16))"))
    ///         if successful
    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookdata)
        external
        returns (bytes4);

    /// @notice Callback on authorized ERC20 transfer.
    /// @dev    Cannot be blocked, can only be used to update state.
    ///         Return value is ignored, only kept for compatibility with V2 share tokens.
    function onERC20AuthTransfer(address sender, address from, address to, uint256 value, HookData calldata hookdata)
        external
        returns (bytes4);

    /// @notice Check if given transfer can be performed
    function checkERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        external
        view
        returns (bool);

    /// @notice Update a set of restriction for a token
    /// @dev    MAY be user specific, which would be included in the encoded `update` value
    function updateRestriction(address token, bytes memory update) external;
}
