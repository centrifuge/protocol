// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "src/misc/interfaces/IERC7575.sol";

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
address constant ESCROW_HOOK_ID = address(uint160(uint8(0xce)));

/// @notice Hook interface to customize share token behaviour
/// @dev    To detect specific system actions:
///           Deposit request:      address(0)      -> address(user)
///           Deposit claim:        ESCROW_HOOK_ID  -> address(user)
///           Redeem request:       address(user)   -> ESCROW_HOOK_ID
///           Redeem claim:         address(user)   -> address(0)
///           Cross-chain transfer: address(user)   -> address(uint160(chainId))
interface IHook is IERC165 {
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
