// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {BitmapLib} from "src/misc/libraries/BitmapLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";

import {IRoot} from "src/vaults/interfaces/IRoot.sol";
import {ITranche} from "src/vaults/interfaces/token/ITranche.sol";
import {IHook, HookData} from "src/vaults/interfaces/token/IHook.sol";
import {MessagesLib} from "src/vaults/libraries/MessagesLib.sol";
import {IERC165} from "src/vaults/interfaces/IERC7575.sol";
import {RestrictionUpdate, IRestrictionManager} from "src/vaults/interfaces/token/IRestrictionManager.sol";

/// @title  Restriction Manager
/// @notice Hook implementation that:
///         * Requires adding accounts to the memberlist before they can receive tokens
///         * Supports freezing accounts which blocks transfers both to and from them
///         * Allows authTransferFrom calls
///
/// @dev    The first 8 bytes (uint64) of hookData is used for the memberlist valid until date,
///         the last bit is used to denote whether the account is frozen.
contract RestrictionManager is Auth, IRestrictionManager, IHook {
    using BitmapLib for *;
    using BytesLib for bytes;

    /// @dev Least significant bit
    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;

    constructor(address root_, address deployer) Auth(deployer) {
        root = IRoot(root_);
    }

    // --- Callback from tranche token ---
    /// @inheritdoc IHook
    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        external
        virtual
        returns (bytes4)
    {
        require(checkERC20Transfer(from, to, value, hookData), "RestrictionManager/transfer-blocked");
        return IHook.onERC20Transfer.selector;
    }

    /// @inheritdoc IHook
    function onERC20AuthTransfer(
        address, /* sender */
        address, /* from */
        address, /* to */
        uint256, /* value */
        HookData calldata /* hookData */
    ) external pure returns (bytes4) {
        return IHook.onERC20AuthTransfer.selector;
    }

    // --- ERC1404 implementation ---
    /// @inheritdoc IHook
    function checkERC20Transfer(address from, address to, uint256, /* value */ HookData calldata hookData)
        public
        view
        returns (bool)
    {
        if (uint128(hookData.from).getBit(FREEZE_BIT) == true && !root.endorsed(from)) {
            // Source is frozen and not endorsed
            return false;
        }

        if (root.endorsed(to) || to == address(0)) {
            // Destination is endorsed and source was already checked, so the transfer is allowed
            return true;
        }

        uint128 toHookData = uint128(hookData.to);
        if (toHookData.getBit(FREEZE_BIT) == true) {
            // Destination is frozen
            return false;
        }

        if (toHookData >> 64 < block.timestamp) {
            // Destination is not a member
            return false;
        }

        return true;
    }

    // --- Incoming message handling ---
    /// @inheritdoc IHook
    function updateRestriction(address token, bytes memory update) external auth {
        RestrictionUpdate updateId = RestrictionUpdate(update.toUint8(0));

        if (updateId == RestrictionUpdate.UpdateMember) updateMember(token, update.toAddress(1), update.toUint64(33));
        else if (updateId == RestrictionUpdate.Freeze) freeze(token, update.toAddress(1));
        else if (updateId == RestrictionUpdate.Unfreeze) unfreeze(token, update.toAddress(1));
        else revert("RestrictionManager/invalid-update");
    }

    /// @inheritdoc IRestrictionManager
    function freeze(address token, address user) public auth {
        require(user != address(0), "RestrictionManager/cannot-freeze-zero-address");
        require(!root.endorsed(user), "RestrictionManager/endorsed-user-cannot-be-frozen");

        uint128 hookData = uint128(ITranche(token).hookDataOf(user));
        ITranche(token).setHookData(user, bytes16(hookData.setBit(FREEZE_BIT, true)));

        emit Freeze(token, user);
    }

    /// @inheritdoc IRestrictionManager
    function unfreeze(address token, address user) public auth {
        uint128 hookData = uint128(ITranche(token).hookDataOf(user));
        ITranche(token).setHookData(user, bytes16(hookData.setBit(FREEZE_BIT, false)));

        emit Unfreeze(token, user);
    }

    /// @inheritdoc IRestrictionManager
    function isFrozen(address token, address user) public view returns (bool) {
        return uint128(ITranche(token).hookDataOf(user)).getBit(FREEZE_BIT);
    }

    // --- Managing members ---
    /// @inheritdoc IRestrictionManager
    function updateMember(address token, address user, uint64 validUntil) public auth {
        require(block.timestamp <= validUntil, "RestrictionManager/invalid-valid-until");
        require(!root.endorsed(user), "RestrictionManager/endorsed-user-cannot-be-updated");

        uint128 hookData = uint128(validUntil) << 64;
        hookData.setBit(FREEZE_BIT, isFrozen(token, user));
        ITranche(token).setHookData(user, bytes16(hookData));

        emit UpdateMember(token, user, validUntil);
    }

    /// @inheritdoc IRestrictionManager
    function isMember(address token, address user) external view returns (bool isValid, uint64 validUntil) {
        validUntil = abi.encodePacked(ITranche(token).hookDataOf(user)).toUint64(0);
        isValid = validUntil >= block.timestamp;
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
