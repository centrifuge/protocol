// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFreezable} from "./interfaces/IFreezable.sol";
import {IMemberlist} from "./interfaces/IMemberlist.sol";
import {UpdateRestrictionType, UpdateRestrictionMessageLib} from "./libraries/UpdateRestrictionMessageLib.sol";

import {Auth} from "../misc/Auth.sol";
import {IAuth} from "../misc/interfaces/IAuth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {IERC165} from "../misc/interfaces/IERC7575.sol";
import {BitmapLib} from "../misc/libraries/BitmapLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {IRoot} from "../core/interfaces/IRoot.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {ITransferHook, HookData, ESCROW_HOOK_ID} from "../core/interfaces/ITransferHook.sol";

import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {IShareToken} from "../core/spoke/interfaces/IShareToken.sol";
import {IUpdateContract} from "../core/spoke/interfaces/IUpdateContract.sol";
import {UpdateContractType, UpdateContractMessageLib} from "../messaging/libraries/UpdateContractMessageLib.sol";

/// @title  BaseTransferHook
/// @dev    The first 8 bytes (uint64) of hookData is used for the memberlist valid until date,
///         the last bit is used to denote whether the account is frozen.
abstract contract BaseTransferHook is Auth, IMemberlist, IFreezable, ITransferHook, IUpdateContract {
    using BitmapLib for *;
    using UpdateRestrictionMessageLib for *;
    using BytesLib for bytes;
    using CastLib for bytes32;

    error InvalidInputs();
    error ShareTokenDoesNotExist();

    /// @dev Least significant bit
    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;
    ISpoke public immutable spoke;
    address public immutable redeemSource;
    address public immutable depositTarget;
    address public immutable crosschainSource;

    mapping(address token => mapping(address => bool)) public manager;

    constructor(
        address root_,
        address spoke_,
        address redeemSource_,
        address depositTarget_,
        address crosschainSource_,
        address deployer
    ) Auth(deployer) {
        require(
            redeemSource_ != depositTarget_ && depositTarget_ != crosschainSource_ && redeemSource_ != crosschainSource_,
            InvalidInputs()
        );

        root = IRoot(root_);
        spoke = ISpoke(spoke_);
        redeemSource = redeemSource_;
        depositTarget = depositTarget_;
        crosschainSource = crosschainSource_;
    }

    /// @dev Check if the msg.sender is ward or a manager
    modifier authOrManager(address token) {
        require(wards[msg.sender] == 1 || manager[token][msg.sender], IAuth.NotAuthorized());
        _;
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

    function checkERC20Transfer(
        address from,
        address to,
        uint256,
        /* value */
        HookData calldata hookData
    ) public view virtual returns (bool);

    function isDepositRequestOrIssuance(address from, address to) public view returns (bool) {
        return from == address(0) && to != depositTarget;
    }

    function isDepositFulfillment(address from, address to) public view returns (bool) {
        return from == address(0) && to == depositTarget;
    }

    function isDepositClaim(address from, address to) public view returns (bool) {
        return from == depositTarget && to != address(0);
    }

    function isRedeemRequest(address, address to) public pure returns (bool) {
        return to == ESCROW_HOOK_ID;
    }

    function isRedeemFulfillment(address from, address to) public view returns (bool) {
        return from == redeemSource && to == address(0);
    }

    function isRedeemClaimOrRevocation(address from, address to) public view returns (bool) {
        return (from != redeemSource && from != crosschainSource) && to == address(0);
    }

    function isCrosschainTransfer(address from, address to) public view returns (bool) {
        return from == crosschainSource && to == address(0);
    }

    function isCrosschainTransferExecution(address from, address to) public view returns (bool) {
        return from == crosschainSource && to != address(0);
    }

    function isSourceOrTargetFrozen(address from, address to, HookData calldata hookData) public view returns (bool) {
        return (uint128(hookData.from).getBit(FREEZE_BIT) == true && !root.endorsed(from))
            || (uint128(hookData.to).getBit(FREEZE_BIT) == true && !root.endorsed(to));
    }

    function isSourceMember(address from, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.from) >> 64 >= block.timestamp || root.endorsed(from);
    }

    function isTargetMember(address to, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.to) >> 64 >= block.timestamp || root.endorsed(to);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IUpdateContract
    function update(PoolId poolId, ShareClassId scId, bytes memory payload) external auth {
        uint8 kind = uint8(UpdateContractMessageLib.updateContractType(payload));

        if (kind == uint8(UpdateContractType.UpdateAddress)) {
            UpdateContractMessageLib.UpdateContractUpdateAddress memory m =
                UpdateContractMessageLib.deserializeUpdateContractUpdateAddress(payload);

            address token = address(spoke.shareToken(poolId, scId));
            require(token != address(0), ShareTokenDoesNotExist());

            manager[token][m.what.toAddress()] = m.isEnabled;
        } else {
            revert UnknownUpdateContractType();
        }
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
    function freeze(address token, address user) public authOrManager(token) {
        require(user != address(0), CannotFreezeZeroAddress());
        require(!root.endorsed(user), EndorsedUserCannotBeFrozen());

        uint128 hookData = uint128(IShareToken(token).hookDataOf(user));
        IShareToken(token).setHookData(user, bytes16(uint128(hookData.withBit(FREEZE_BIT, true))));

        emit Freeze(token, user);
    }

    /// @inheritdoc IFreezable
    function unfreeze(address token, address user) public authOrManager(token) {
        uint128 hookData = uint128(IShareToken(token).hookDataOf(user));
        IShareToken(token).setHookData(user, bytes16(uint128(hookData.withBit(FREEZE_BIT, false))));

        emit Unfreeze(token, user);
    }

    /// @inheritdoc IFreezable
    function isFrozen(address token, address user) public view returns (bool) {
        return uint128(IShareToken(token).hookDataOf(user)).getBit(FREEZE_BIT);
    }

    /// @inheritdoc IMemberlist
    function updateMember(address token, address user, uint64 validUntil) public authOrManager(token) {
        require(block.timestamp <= validUntil, InvalidValidUntil());
        require(!root.endorsed(user), EndorsedUserCannotBeUpdated());

        uint128 hookData = uint128(validUntil) << 64;
        hookData = uint128(uint256(hookData).withBit(FREEZE_BIT, isFrozen(token, user)));
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
