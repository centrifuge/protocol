// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IFreezable} from "./interfaces/IFreezable.sol";
import {IMemberlist} from "./interfaces/IMemberlist.sol";
import {IBaseTransferHook} from "./interfaces/IBaseTransferHook.sol";
import {UpdateRestrictionType, UpdateRestrictionMessageLib} from "./libraries/UpdateRestrictionMessageLib.sol";

import {Auth} from "../../misc/Auth.sol";
import {IAuth} from "../../misc/interfaces/IAuth.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {BytesLib} from "../../misc/libraries/BytesLib.sol";
import {IERC165} from "../../misc/interfaces/IERC7575.sol";
import {BitmapLib} from "../../misc/libraries/BitmapLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {IPoolEscrowProvider} from "../../core/spoke/factories/interfaces/IPoolEscrowFactory.sol";

import {IRoot} from "../../admin/interfaces/IRoot.sol";

import {IShareToken} from "../interfaces/IShareToken.sol";
import {ITransferHook, HookData, ESCROW_HOOK_ID} from "../interfaces/ITransferHook.sol";

/// @title  BaseTransferHook
/// @notice Abstract base contract for share token transfer restrictions that provides memberlist management,
///         account freezing capabilities, and cross-chain message handling, while encoding member validity
///         and freeze status in the hookData structure for efficient on-chain verification.
/// @dev    The first 8 bytes (uint64) of hookData is used for the memberlist valid until date,
///         the last bit is used to denote whether the account is frozen.
abstract contract BaseTransferHook is Auth, IMemberlist, IFreezable, IManagerCallFromHub, IBaseTransferHook {
    using BitmapLib for *;
    using UpdateRestrictionMessageLib for *;
    using BytesLib for bytes;
    using CastLib for bytes32;

    error InvalidInputs();
    error ShareTokenDoesNotExist();

    /// @dev Least significant bit
    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;
    address public immutable envoy;
    ISpokeRegistry public immutable spokeRegistry;
    address public immutable crosschainSource;
    ISpoke public immutable spoke;
    IPoolEscrowProvider public immutable poolEscrowProvider;

    mapping(address token => mapping(address => bool)) public manager;

    constructor(
        address root_,
        address envoy_,
        address spokeRegistry_,
        address spoke_,
        address crosschainSource_,
        address deployer,
        address poolEscrowProvider_
    ) Auth(deployer) {
        require(spoke_ != crosschainSource_, InvalidInputs());

        root = IRoot(root_);
        envoy = envoy_;
        spokeRegistry = ISpokeRegistry(spokeRegistry_);
        spoke = ISpoke(spoke_);
        crosschainSource = crosschainSource_;
        poolEscrowProvider = IPoolEscrowProvider(poolEscrowProvider_);
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
        return !poolEscrowProvider.poolId(addr).isNull();
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
        return from == address(spoke) && to == address(0);
    }

    function isRedeemClaimOrRevocation(address from, address to) public view returns (bool) {
        return (from != address(spoke) && from != crosschainSource) && to == address(0);
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

    /// @inheritdoc IManagerCallFromHub
    /// @dev The share class id is encoded in `payload` (fromHub carries no scId).
    function fromHub(PoolId poolId, bytes calldata payload) external payable virtual {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (bytes16 scId_, uint8 kindValue) = abi.decode(payload, (bytes16, uint8));
        require(kindValue <= uint8(type(TrustedCall).max), UnknownTrustedCall());
        ShareClassId scId = ShareClassId.wrap(scId_);

        TrustedCall kind = TrustedCall(kindValue);
        if (kind == TrustedCall.UpdateHookManager) {
            (,, bytes32 manager_, bool canManage) = abi.decode(payload, (bytes16, uint8, bytes32, bool));
            address token = address(spokeRegistry.shareToken(poolId, scId));
            require(token != address(0), ShareTokenDoesNotExist());

            manager[token][manager_.toAddress()] = canManage;
            emit UpdateHookManager(token, manager_.toAddress(), canManage);
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
