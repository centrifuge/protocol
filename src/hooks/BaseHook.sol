// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {BytesLib} from "src/misc/libraries/BytesLib.sol";
import {IERC165} from "src/misc/interfaces/IERC7575.sol";
import {BitmapLib} from "src/misc/libraries/BitmapLib.sol";

import {IRoot} from "src/common/interfaces/IRoot.sol";
import {ITransferHook, HookData, ESCROW_HOOK_ID} from "src/common/interfaces/ITransferHook.sol";

import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";

import {IFreezable} from "src/hooks/interfaces/IFreezable.sol";
import {IMemberlist} from "src/hooks/interfaces/IMemberlist.sol";
import {UpdateRestrictionType, UpdateRestrictionMessageLib} from "src/hooks/libraries/UpdateRestrictionMessageLib.sol";

/// @title  BaseHook
/// @dev    The first 8 bytes (uint64) of hookData is used for the memberlist valid until date,
///         the last bit is used to denote whether the account is frozen.
abstract contract BaseHook is Auth, IMemberlist, IFreezable, ITransferHook {
    using BitmapLib for *;
    using UpdateRestrictionMessageLib for *;
    using BytesLib for bytes;
    using CastLib for bytes32;

    /// @dev Least significant bit
    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;

    constructor(address root_, address deployer) Auth(deployer) {
        root = IRoot(root_);
    }

    //----------------------------------------------------------------------------------------------
    // Callback from share token
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITransferHook
    function onERC20Transfer(address from, address to, uint256 value, HookData calldata hookData)
        external
        virtual
        returns (bytes4)
    {
        require(checkERC20Transfer(from, to, value, hookData), TransferBlocked());
        return ITransferHook.onERC20Transfer.selector;
    }

    /// @inheritdoc ITransferHook
    function onERC20AuthTransfer(
        address, /* sender */
        address, /* from */
        address, /* to */
        uint256, /* value */
        HookData calldata /* hookData */
    ) external pure virtual returns (bytes4) {
        return ITransferHook.onERC20AuthTransfer.selector;
    }

    function checkERC20Transfer(address from, address to, uint256, /* value */ HookData calldata hookData)
        public
        view
        virtual
        returns (bool);

    function isDepositRequest(address from, address to) public view returns (bool) {
        return from == address(0) && to != ESCROW_HOOK_ID;
    }

    function isDepositFulfillment(address from, address to) public view returns (bool) {
        return from == address(0) && to == ESCROW_HOOK_ID;
    }

    function isDepositClaim(address from, address to) public view returns (bool) {
        return from == ESCROW_HOOK_ID && to != address(0);
    }

    function isRedeemRequest(address from, address to) public view returns (bool) {
        return from != address(0) && from != ESCROW_HOOK_ID && to == ESCROW_HOOK_ID;
    }

    function isRedeemFulfillment(address from, address to) public view returns (bool) {
        return from == ESCROW_HOOK_ID && to == address(0);
    }

    function isRedeemClaim(address from, address to) public view returns (bool) {
        return from != ESCROW_HOOK_ID && to == address(0);
    }

    // TODO: separate into isRedeemClaim and isCrosschainTransfer,
    // by checking from == spoke && to == address(0)

    // function isCrosschainTransfer(address from, address to) public view returns (bool) {
    //     return from != ESCROW_HOOK_ID && to == address(0);
    // }

    function isSourceOrTargetFrozen(HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.from).getBit(FREEZE_BIT) == true || uint128(hookData.to).getBit(FREEZE_BIT) == true;
    }

    function isSourceMember(address from, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.from) >> 64 >= block.timestamp || root.endorsed(from);
    }

    function isTargetMember(address to, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.to) >> 64 >= block.timestamp || root.endorsed(to);
    }

    //----------------------------------------------------------------------------------------------
    // Restriction updates
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITransferHook
    function updateRestriction(address token, bytes memory payload) external auth {
        UpdateRestrictionType updateId = payload.updateRestrictionType();

        if (updateId == UpdateRestrictionType.Member) {
            UpdateRestrictionMessageLib.UpdateRestrictionMember memory m = payload.deserializeUpdateRestrictionMember();
            updateMember(token, m.user.toAddress(), m.validUntil);
        } else if (updateId == UpdateRestrictionType.Freeze) {
            UpdateRestrictionMessageLib.UpdateRestrictionFreeze memory m = payload.deserializeUpdateRestrictionFreeze();
            freeze(token, m.user.toAddress());
        } else if (updateId == UpdateRestrictionType.Unfreeze) {
            UpdateRestrictionMessageLib.UpdateRestrictionUnfreeze memory m =
                payload.deserializeUpdateRestrictionUnfreeze();
            unfreeze(token, m.user.toAddress());
        } else {
            revert InvalidUpdate();
        }
    }

    /// @inheritdoc IFreezable
    function freeze(address token, address user) public auth {
        require(user != address(0), CannotFreezeZeroAddress());
        require(!root.endorsed(user), EndorsedUserCannotBeFrozen());

        uint128 hookData = uint128(IShareToken(token).hookDataOf(user));
        IShareToken(token).setHookData(user, bytes16(hookData.withBit(FREEZE_BIT, true)));

        emit Freeze(token, user);
    }

    /// @inheritdoc IFreezable
    function unfreeze(address token, address user) public auth {
        uint128 hookData = uint128(IShareToken(token).hookDataOf(user));
        IShareToken(token).setHookData(user, bytes16(hookData.withBit(FREEZE_BIT, false)));

        emit Unfreeze(token, user);
    }

    /// @inheritdoc IFreezable
    function isFrozen(address token, address user) public view returns (bool) {
        return uint128(IShareToken(token).hookDataOf(user)).getBit(FREEZE_BIT);
    }

    /// @inheritdoc IMemberlist
    function updateMember(address token, address user, uint64 validUntil) public auth {
        require(block.timestamp <= validUntil, InvalidValidUntil());
        require(!root.endorsed(user), EndorsedUserCannotBeUpdated());

        uint128 hookData = uint128(validUntil) << 64;
        hookData = hookData.withBit(FREEZE_BIT, isFrozen(token, user));
        IShareToken(token).setHookData(user, bytes16(hookData));

        emit UpdateMember(token, user, validUntil);
    }

    /// @inheritdoc IMemberlist
    function isMember(address token, address user) external view returns (bool isValid, uint64 validUntil) {
        validUntil = abi.encodePacked(IShareToken(token).hookDataOf(user)).toUint64(0);
        isValid = validUntil >= block.timestamp;
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure override returns (bool) {
        return interfaceId == type(ITransferHook).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}
