// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFreezable} from "./interfaces/IFreezable.sol";
import {IMemberlist} from "./interfaces/IMemberlist.sol";
import {IBaseTransferHook} from "./interfaces/IBaseTransferHook.sol";
import {UpdateRestrictionType, UpdateRestrictionMessageLib} from "./libraries/UpdateRestrictionMessageLib.sol";

import {Auth} from "../misc/Auth.sol";
import {IAuth} from "../misc/interfaces/IAuth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {BytesLib} from "../misc/libraries/BytesLib.sol";
import {IERC165} from "../misc/interfaces/IERC7575.sol";
import {BitmapLib} from "../misc/libraries/BitmapLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {IShareToken} from "../core/spoke/interfaces/IShareToken.sol";
import {IBalanceSheet} from "../core/spoke/interfaces/IBalanceSheet.sol";
import {ITrustedContractUpdate} from "../core/utils/interfaces/IContractUpdate.sol";
import {IPoolEscrowProvider} from "../core/spoke/factories/interfaces/IPoolEscrowFactory.sol";
import {ITransferHook, HookData, ESCROW_HOOK_ID} from "../core/spoke/interfaces/ITransferHook.sol";

import {IRoot} from "../admin/interfaces/IRoot.sol";

/// @title  BaseTransferHook
/// @notice Abstract base contract for share token transfer restrictions that provides memberlist management,
///         account freezing capabilities, and cross-chain message handling, while encoding member validity
///         and freeze status in the hookData structure for efficient on-chain verification.
/// @dev    The first 8 bytes (uint64) of hookData is used for the memberlist valid until date,
///         the last bit is used to denote whether the account is frozen.
abstract contract BaseTransferHook is Auth, IMemberlist, IFreezable, ITrustedContractUpdate, IBaseTransferHook {
    using BitmapLib for *;
    using UpdateRestrictionMessageLib for *;
    using BytesLib for bytes;
    using CastLib for bytes32;

    error InvalidInputs();
    error ShareTokenDoesNotExist();
    error EscrowDoesNotExist();

    /// @dev Least significant bit
    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;
    ISpoke public immutable spoke;
    address public immutable poolEscrow;
    address public immutable crosschainSource;
    IBalanceSheet public immutable balanceSheet;
    IPoolEscrowProvider public immutable poolEscrowProvider;

    mapping(address token => mapping(address => bool)) public manager;
    mapping(address poolEscrow => bool) public isAPoolEscrow;

    constructor(
        address root_,
        address spoke_,
        address balanceSheet_,
        address crosschainSource_,
        address deployer,
        address poolEscrowProvider_,
        address poolEscrow_
    ) Auth(deployer) {
        require(balanceSheet_ != crosschainSource_, InvalidInputs());

        root = IRoot(root_);
        spoke = ISpoke(spoke_);
        balanceSheet = IBalanceSheet(balanceSheet_);
        crosschainSource = crosschainSource_;
        poolEscrowProvider = IPoolEscrowProvider(poolEscrowProvider_);
        poolEscrow = poolEscrow_;
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
    )
        external
        pure
        virtual
        returns (bytes4)
    {
        return ITransferHook.onERC20AuthTransfer.selector;
    }

    function checkERC20Transfer(
        address from,
        address to,
        uint256,
        /* value */
        HookData calldata hookData
    )
        public
        view
        virtual
        returns (bool);

    function isPoolEscrow(address addr) public view returns (bool) {
        // Fast path: single-pool optimization
        if (poolEscrow != address(0)) return addr == poolEscrow;

        // Multi-pool path: no code shortcut
        if (addr.code.length == 0) return false;

        return isAPoolEscrow[addr];
    }

    function isDepositRequestOrIssuance(address from, address to) public view returns (bool) {
        return from == address(0) && !isPoolEscrow(to) && to != crosschainSource;
    }

    function isDepositFulfillment(address from, address to) public view returns (bool) {
        return from == address(0) && isPoolEscrow(to);
    }

    function isDepositClaim(address from, address to) public view returns (bool) {
        return isPoolEscrow(from) && to != address(0);
    }

    function isRedeemRequest(address, address to) public pure returns (bool) {
        return to == ESCROW_HOOK_ID;
    }

    function isRedeemFulfillment(address from, address to) public view returns (bool) {
        return from == address(balanceSheet) && to == address(0);
    }

    function isRedeemClaimOrRevocation(address from, address to) public view returns (bool) {
        return (from != address(balanceSheet) && from != crosschainSource) && to == address(0);
    }

    function isCrosschainTransfer(address from, address to) public view returns (bool) {
        return from == crosschainSource && to == address(0);
    }

    function isCrosschainTransferExecution(address from, address to) public view returns (bool) {
        return from == crosschainSource && to != address(0);
    }

    function isSourceOrTargetFrozen(address from, address to, HookData calldata hookData) public view returns (bool) {
        return (uint128(hookData.from).getBit(FREEZE_BIT) == true && !isPoolEscrow(from))
            || (uint128(hookData.to).getBit(FREEZE_BIT) == true && !isPoolEscrow(to));
    }

    function isSourceMember(address from, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.from) >> 64 >= block.timestamp || isPoolEscrow(from);
    }

    function isTargetMember(address to, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.to) >> 64 >= block.timestamp || root.endorsed(to) || isPoolEscrow(to);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITrustedContractUpdate
    function trustedCall(PoolId poolId, ShareClassId scId, bytes memory payload) external virtual auth {
        uint8 kindValue = abi.decode(payload, (uint8));
        require(kindValue <= uint8(type(TrustedCall).max), UnknownTrustedCall());

        TrustedCall kind = TrustedCall(kindValue);
        if (kind == TrustedCall.UpdateHookManager) {
            (, bytes32 manager_, bool canManage) = abi.decode(payload, (uint8, bytes32, bool));
            address token = address(spoke.shareToken(poolId, scId));
            require(token != address(0), ShareTokenDoesNotExist());

            manager[token][manager_.toAddress()] = canManage;
            emit UpdateHookManager(token, manager_.toAddress(), canManage);
        }
    }

    function registerPoolEscrow(PoolId poolId) external auth {
        address escrow = address(poolEscrowProvider.escrow(poolId));
        require(escrow != address(0), EscrowDoesNotExist());

        isAPoolEscrow[escrow] = true;
        emit RegisterPoolEscrow(escrow);
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
        require(!root.endorsed(user) && !isPoolEscrow(user), EndorsedUserCannotBeFrozen());

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
        require(!root.endorsed(user) && !isPoolEscrow(user), EndorsedUserCannotBeUpdated());

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
