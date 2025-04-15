// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {BitmapLib} from "src/misc/libraries/BitmapLib.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {UpdateRestrictionType, MessageLib} from "src/common/libraries/MessageLib.sol";

import {IERC165} from "src/vaults/interfaces/IERC7575.sol";
import {IHook, HookData} from "src/vaults/interfaces/token/IHook.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";

import {IRestrictedTransfers} from "src/hooks/interfaces/IRestrictedTransfers.sol";

/// @title  Restricted Redemptions
/// @notice Hook implementation that:
///         * Allows any non-frozen account to receive tokens and transfer tokens
///         * Requires accounts to be added as a member before submitting a redemption request
///         * Supports freezing accounts which blocks transfers both to and from them
///         * Allows authTransferFrom calls
///
/// @dev    The first 8 bytes (uint64) of hookData is used for the memberlist valid until date,
///         the last bit is used to denote whether the account is frozen.
contract FreelyTransferable is Auth, IRestrictedTransfers, IHook {
    using BitmapLib for *;
    using MessageLib for *;
    using BytesLib for bytes;
    using CastLib for bytes32;

    /// @dev Least significant bit
    uint8 public constant FREEZE_BIT = 0;
    /// @dev Magic address denoting a transfer to the escrow
    /// @dev Solely used for gas saving since escrow is per pool
    address public constant ESCROW_IDENTIFIER = address(uint160(uint8(0xce)));

    IRoot public immutable root;

    constructor(address root_, address deployer) Auth(deployer) {
        root = IRoot(root_);
    }

    // --- Callback from share token ---
    /// @inheritdoc IHook
    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        external
        virtual
        returns (bytes4)
    {
        require(checkERC20Transfer(from, to, value, hookData), TransferBlocked());
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
        uint128 fromHookData = uint128(hookData.from);
        if (fromHookData.getBit(FREEZE_BIT) == true && !root.endorsed(from)) {
            // Source is frozen and not endorsed
            return false;
        }

        uint128 toHookData = uint128(hookData.to);
        if (toHookData.getBit(FREEZE_BIT) == true) {
            // Destination is frozen
            return false;
        }

        if (from == address(0) && to == ESCROW_IDENTIFIER) {
            // Deposit request fulfillment
            return true;
        }

        if (to == ESCROW_IDENTIFIER && fromHookData >> 64 < block.timestamp) {
            // Destination is escrow, so it's a redemption request, and the user is not a member
            return false;
        }

        return true;
    }

    // --- Incoming message handling ---
    /// @inheritdoc IHook
    function updateRestriction(address token, bytes memory payload) external auth {
        UpdateRestrictionType updateId = payload.updateRestrictionType();

        if (updateId == UpdateRestrictionType.Member) {
            MessageLib.UpdateRestrictionMember memory m = payload.deserializeUpdateRestrictionMember();
            updateMember(token, m.user.toAddress(), m.validUntil);
        } else if (updateId == UpdateRestrictionType.Freeze) {
            MessageLib.UpdateRestrictionFreeze memory m = payload.deserializeUpdateRestrictionFreeze();
            freeze(token, m.user.toAddress());
        } else if (updateId == UpdateRestrictionType.Unfreeze) {
            MessageLib.UpdateRestrictionUnfreeze memory m = payload.deserializeUpdateRestrictionUnfreeze();
            unfreeze(token, m.user.toAddress());
        } else {
            revert InvalidUpdate();
        }
    }

    /// @inheritdoc IRestrictedTransfers
    function freeze(address token, address user) public auth {
        require(user != address(0), CannotFreezeZeroAddress());
        require(!root.endorsed(user), EndorsedUserCannotBeFrozen());

        uint128 hookData = uint128(IShareToken(token).hookDataOf(user));
        IShareToken(token).setHookData(user, bytes16(hookData.setBit(FREEZE_BIT, true)));

        emit Freeze(token, user);
    }

    /// @inheritdoc IRestrictedTransfers
    function unfreeze(address token, address user) public auth {
        uint128 hookData = uint128(IShareToken(token).hookDataOf(user));
        IShareToken(token).setHookData(user, bytes16(hookData.setBit(FREEZE_BIT, false)));

        emit Unfreeze(token, user);
    }

    /// @inheritdoc IRestrictedTransfers
    function isFrozen(address token, address user) public view returns (bool) {
        return uint128(IShareToken(token).hookDataOf(user)).getBit(FREEZE_BIT);
    }

    // --- Managing members ---
    /// @inheritdoc IRestrictedTransfers
    function updateMember(address token, address user, uint64 validUntil) public auth {
        require(block.timestamp <= validUntil, InvalidValidUntil());
        require(!root.endorsed(user), EndorsedUserCannotBeUpdated());

        uint128 hookData = uint128(validUntil) << 64;
        hookData.setBit(FREEZE_BIT, isFrozen(token, user));
        IShareToken(token).setHookData(user, bytes16(hookData));

        emit UpdateMember(token, user, validUntil);
    }

    /// @inheritdoc IRestrictedTransfers
    function isMember(address token, address user) external view returns (bool isValid, uint64 validUntil) {
        validUntil = abi.encodePacked(IShareToken(token).hookDataOf(user)).toUint64(0);
        isValid = validUntil >= block.timestamp;
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(IHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
