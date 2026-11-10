// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../../../src/misc/Auth.sol";
import {IAuth} from "../../../src/misc/interfaces/IAuth.sol";
import {CastLib} from "../../../src/misc/libraries/CastLib.sol";
import {BytesLib} from "../../../src/misc/libraries/BytesLib.sol";
import {IERC165} from "../../../src/misc/interfaces/IERC7575.sol";
import {BitmapLib} from "../../../src/misc/libraries/BitmapLib.sol";

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ISpoke} from "../../../src/core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {IManagerCallFromHub} from "../../../src/core/utils/interfaces/IManagerCall.sol";
import {IEscrowProvider} from "../../../src/core/spoke/factories/interfaces/IEscrowFactory.sol";
import {ISpokeRegistry, VaultDetails} from "../../../src/core/spoke/interfaces/ISpokeRegistry.sol";

import {IRoot} from "../../../src/admin/interfaces/IRoot.sol";

import {IFreezable} from "../../../src/token/hooks/interfaces/IFreezable.sol";
import {IMemberlist} from "../../../src/token/hooks/interfaces/IMemberlist.sol";
import {IShareTokenHook} from "../../../src/token/hooks/interfaces/IShareTokenHook.sol";
import {
    UpdateRestrictionType,
    UpdateRestrictionMessageLib
} from "../../../src/token/hooks/libraries/UpdateRestrictionMessageLib.sol";

import {VaultAction} from "../mocks/VaultActionCheck.sol";

import {RoleCheck} from "../../../src/token/interfaces/IRoleHook.sol";
import {IShareToken} from "../../../src/token/interfaces/IShareToken.sol";
import {ITransferHook, HookData} from "../../../src/token/interfaces/ITransferHook.sol";

/// @title  LegacyShareTokenHook
/// @notice Abstract base contract for share token transfer restrictions that provides memberlist management,
///         account freezing capabilities, and cross-chain message handling, while encoding member validity
///         and freeze status in the hookData structure for efficient on-chain verification.
/// @dev    The first 8 bytes (uint64) of hookData is used for the memberlist valid until date,
///         the last bit is used to denote whether the account is frozen.
abstract contract LegacyShareTokenHook is Auth, IMemberlist, IFreezable, IManagerCallFromHub, IShareTokenHook {
    using BitmapLib for *;
    using BytesLib for bytes;
    using CastLib for bytes32;
    using UpdateRestrictionMessageLib for *;

    /// @dev Least significant bit
    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;
    address public immutable envoy;
    ISpokeRegistry public immutable spokeRegistry;
    address public immutable crosschainSource;
    ISpoke public immutable spoke;
    IEscrowProvider public immutable escrowProvider;

    mapping(address token => mapping(address => bool)) public manager;

    constructor(
        address root_,
        address envoy_,
        address spokeRegistry_,
        address spoke_,
        address crosschainSource_,
        address deployer,
        address escrowProvider_
    ) Auth(deployer) {
        require(spoke_ != crosschainSource_, InvalidInputs());

        root = IRoot(root_);
        envoy = envoy_;
        spokeRegistry = ISpokeRegistry(spokeRegistry_);
        spoke = ISpoke(spoke_);
        crosschainSource = crosschainSource_;
        escrowProvider = IEscrowProvider(escrowProvider_);
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

    /// @dev Not part of the legacy hook; the interface asks for it, and the legacy flavors have no table to read.
    function policy() external pure returns (uint8) {
        revert();
    }

    /// @dev Not part of the legacy hook; the interface now asks for it, answered from the legacy classifiers.
    function leg(address from, address to) external view returns (Kind) {
        if (isIssuance(from, to)) return Kind.Mint;
        if (isDepositClaim(from, to)) return Kind.Release;
        if (isRedeemFulfillment(from, to)) return Kind.Fulfill;
        if (isRedeemClaimOrRevocation(from, to)) return Kind.Burn;
        return Kind.Transfer;
    }

    function isEscrow(address addr) public view returns (bool) {
        return !escrowProvider.poolId(addr).isNull();
    }

    function isIssuance(address from, address to) public view returns (bool) {
        return from == address(0) && !isEscrow(to) && to != crosschainSource;
    }

    function isDepositFulfillment(address from, address to) public view returns (bool) {
        return from == address(0) && isEscrow(to);
    }

    function isDepositClaim(address from, address to) public view returns (bool) {
        return isEscrow(from) && to != address(0);
    }

    function isRedeemFulfillment(address from, address to) public view returns (bool) {
        return from == address(spoke) && to == address(0);
    }

    function isRedeemClaimOrRevocation(address from, address to) public view returns (bool) {
        return (from != address(spoke) && from != crosschainSource) && to == address(0);
    }

    function isCrosschainTransfer(address, address to) public pure returns (bool) {
        return to != address(0) && uint160(to) <= type(uint16).max;
    }

    function isCrosschainTransferExecution(address from, address to) public view returns (bool) {
        return from == crosschainSource && to != address(0);
    }

    function isSourceOrTargetFrozen(address from, address to, HookData calldata hookData) public view returns (bool) {
        return (uint128(hookData.from).getBit(FREEZE_BIT) && !_isFreezeExempt(msg.sender, from))
            || (uint128(hookData.to).getBit(FREEZE_BIT) && !_isFreezeExempt(msg.sender, to));
    }

    function isShareClassVault(address token, address addr) public view returns (bool) {
        VaultDetails memory details = spokeRegistry.vaultDetails(addr);
        return details.isLinked && address(spokeRegistry.shareToken(details.poolId, details.scId)) == token;
    }

    function isSourceMember(address from, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.from) >> 64 >= block.timestamp || isEscrow(from);
    }

    function isTargetMember(address to, HookData calldata hookData) public view returns (bool) {
        return uint128(hookData.to) >> 64 >= block.timestamp || root.endorsed(to) || isEscrow(to);
    }

    //----------------------------------------------------------------------------------------------
    // Vault actions
    //----------------------------------------------------------------------------------------------

    /// @dev The legacy hook answered vault actions itself, before the vault mapped them to role checks.
    function onAction(address token, VaultAction calldata action) external virtual returns (bytes4) {
        require(checkAction(token, action), TransferBlocked());
        return LegacyShareTokenHook.onAction.selector;
    }

    function checkAction(address token, VaultAction calldata action) public view returns (bool) {
        return _checkVaultAction(token, action);
    }

    /// @dev The legacy hook predates role checks, and limits no amount.
    function maxAllowed(address, RoleCheck[] calldata) external pure returns (uint256, uint256) {
        return (type(uint256).max, type(uint256).max);
    }

    /// @dev The legacy hook predates role checks.
    function onRoles(address, RoleCheck[] calldata) external pure returns (bytes4) {
        revert TransferBlocked();
    }

    function checkRoles(address, RoleCheck[] calldata) external pure returns (bool) {
        return false;
    }

    /// @dev Per-flavor policy for vault actions, mirroring the transfer policy on the equivalent
    ///      parties. Implementations MUST fail closed on unknown kinds.
    function _checkVaultAction(address token, VaultAction calldata action) internal view virtual returns (bool);

    /// @dev An escrow counts as a member, as in `isSourceMember`/`isTargetMember`, so a vault action
    ///      paying into an escrow (a fund-of-funds claim) passes wherever the equivalent transfer would.
    function _memberOf(address token, address user) internal view returns (bool) {
        return uint128(IShareToken(token).hookDataOf(user)) >> 64 >= block.timestamp || isEscrow(user);
    }

    function _memberOrEndorsedOf(address token, address user) internal view returns (bool) {
        return _memberOf(token, user) || root.endorsed(user);
    }

    /// @dev The freeze bit as `isSourceOrTargetFrozen` reads it: ignored on an escrow and on a
    ///      vault of `token`'s own share class.
    function _frozenOf(address token, address user) internal view returns (bool) {
        return isFrozen(token, user) && !_isFreezeExempt(token, user);
    }

    /// @dev An escrow, or a linked vault of `token`'s share class (which holds shares mid-revoke).
    function _isFreezeExempt(address token, address user) internal view returns (bool) {
        return isEscrow(user) || isShareClassVault(token, user);
    }

    /// @dev The owner and any distinct controller must be unfrozen, current members; endorsement does
    ///      not substitute, matching `isSourceMember`.
    function _checkRedeemRequestParties(address token, VaultAction calldata action) internal view returns (bool) {
        if (_frozenOf(token, action.owner) || !_memberOf(token, action.owner)) return false;
        return action.controller == action.owner
            || (!_frozenOf(token, action.controller) && _memberOf(token, action.controller));
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
        require(!root.endorsed(user) && !isEscrow(user), EndorsedUserCannotBeFrozen());
        require(!isShareClassVault(token, user), VaultCannotBeFrozen());

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
