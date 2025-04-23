// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC20Metadata} from "src/misc/interfaces/IERC20.sol";
import {IERC7575Share} from "src/misc/interfaces/IERC7575.sol";

interface IERC1404 {
    /// @notice Detects if a transfer will be reverted and if so returns an appropriate reference code
    /// @param from Sending address
    /// @param to Receiving address
    /// @param value Amount of tokens being transferred
    /// @return Code by which to reference message for rejection reasoning
    /// @dev Overwrite with your custom transfer restriction logic
    function detectTransferRestriction(address from, address to, uint256 value) external view returns (uint8);

    /// @notice Returns a human-readable message for a given restriction code
    /// @param restrictionCode Identifier for looking up a message
    /// @return Text showing the restriction's reasoning
    /// @dev Overwrite with your custom message and restrictionCode handling
    function messageForTransferRestriction(uint8 restrictionCode) external view returns (string memory);
}

interface IShareToken is IERC20Metadata, IERC7575Share, IERC1404 {
    // --- Events ---
    event File(bytes32 indexed what, address data);
    event SetHookData(address indexed user, bytes16 data);

    // --- Errors ---
    error NotAuthorizedOrHook();
    error ExceedsMaxSupply();
    error RestrictionsFailed();

    struct Balance {
        /// @dev The user balance is limited to uint128. This is safe because the decimals are limited to 18,
        ///      thus the max balance is 2^128-1 / 10**18 = 3.40 * 10**20. This is also enforced on mint.
        uint128 amount;
        /// @dev There are 16 bytes that are used to store hook data (e.g. restrictions for users).
        bytes16 hookData;
    }

    // --- Administration ---
    /// @notice returns the hook that transfers perform callbacks to
    /// @dev    MUST comply to `IHook` interface
    function hook() external view returns (address);

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'name', 'symbol'
    function file(bytes32 what, string memory data) external;

    /// @notice Updates a contract parameter
    /// @param what Accepts a bytes32 representation of 'hook'
    function file(bytes32 what, address data) external;

    /// @notice updates the vault for a given `asset`
    function updateVault(address asset, address vault_) external;

    // --- ERC20 overrides ---
    /// @notice returns the 16 byte hook data of the given `user`.
    /// @dev    Stored in the 128 most significant bits of the user balance
    function hookDataOf(address user) external view returns (bytes16);

    /// @notice update the 16 byte hook data of the given `user`
    function setHookData(address user, bytes16 hookData) external;

    /// @notice Function to mint tokens
    function mint(address user, uint256 value) external;

    /// @notice Function to burn tokens
    function burn(address user, uint256 value) external;

    /// @notice Checks if the tokens can be transferred given the input values
    function checkTransferRestriction(address from, address to, uint256 value) external view returns (bool);

    /// @notice Performs an authorized transfer, with `sender` as the given sender.
    /// @dev    Requires allowance if `sender` != `from`
    function authTransferFrom(address sender, address from, address to, uint256 amount) external returns (bool);
}
