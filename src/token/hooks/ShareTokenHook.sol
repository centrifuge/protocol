// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {HookPolicies} from "./HookPolicies.sol";
import {IFreezable} from "./interfaces/IFreezable.sol";
import {IMemberlist} from "./interfaces/IMemberlist.sol";
import {IShareTokenHook} from "./interfaces/IShareTokenHook.sol";
import {UpdateRestrictionType, UpdateRestrictionMessageLib} from "./libraries/UpdateRestrictionMessageLib.sol";

import {Auth} from "../../misc/Auth.sol";
import {IAuth} from "../../misc/interfaces/IAuth.sol";
import {CastLib} from "../../misc/libraries/CastLib.sol";
import {IERC165} from "../../misc/interfaces/IERC7575.sol";
import {BitmapLib} from "../../misc/libraries/BitmapLib.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ISpoke} from "../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IManagerCallFromHub} from "../../core/utils/interfaces/IManagerCall.sol";
import {IEscrowProvider} from "../../core/spoke/factories/interfaces/IEscrowFactory.sol";
import {ISpokeRegistry, VaultDetails} from "../../core/spoke/interfaces/ISpokeRegistry.sol";

import {IRoot} from "../../admin/interfaces/IRoot.sol";

import {IShareToken} from "../interfaces/IShareToken.sol";
import {IRoleHook, Role, RoleCheck} from "../interfaces/IRoleHook.sol";
import {ITransferHook, HookData} from "../interfaces/ITransferHook.sol";

/// @title  ShareTokenHook
/// @notice Share token transfer restrictions that provide memberlist management, account freezing capabilities,
///         and cross-chain message handling, while encoding member validity and freeze status in the hookData
///         structure for efficient on-chain verification. Deployed with a `Policy` saying which roles ask for
///         membership, usually one of `HookPolicies`; a hook with a rule of its own extends it.
/// @dev    A user's hook data is the memberlist valid-until date in its high 64 bits and the freeze flag in bit 0.
contract ShareTokenHook is Auth, IMemberlist, IFreezable, IManagerCallFromHub, IShareTokenHook {
    using BitmapLib for *;
    using CastLib for bytes32;
    using UpdateRestrictionMessageLib for *;

    uint8 public constant FREEZE_BIT = 0;

    IRoot public immutable root;
    uint8 public immutable policy;
    ISpoke public immutable spoke;
    address public immutable envoy;
    address public immutable crosschainSource;
    ISpokeRegistry public immutable spokeRegistry;
    IEscrowProvider public immutable escrowProvider;

    mapping(address token => mapping(address => bool)) public manager;

    constructor(
        address root_,
        address envoy_,
        address spokeRegistry_,
        address spoke_,
        address crosschainSource_,
        address deployer,
        address escrowProvider_,
        uint8 policy_
    ) Auth(deployer) {
        require(spoke_ != crosschainSource_, InvalidInputs());

        policy = policy_;

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
    // Management
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IManagerCallFromHub
    /// @dev The share class id is encoded in `payload` (fromHub carries no scId).
    function fromHub(PoolId poolId, bytes calldata payload) external payable virtual {
        require(msg.sender == envoy, NotEnvoy());
        require(msg.value == 0, UnexpectedValue());

        (bytes16 scId_, uint8 kindValue) = abi.decode(payload, (bytes16, uint8));
        require(kindValue == uint8(TrustedCall.UpdateHookManager), UnknownTrustedCall());
        ShareClassId scId = ShareClassId.wrap(scId_);

        (,, bytes32 party, bool allowed) = abi.decode(payload, (bytes16, uint8, bytes32, bool));
        address token = address(spokeRegistry.shareToken(poolId, scId));
        require(token != address(0), ShareTokenDoesNotExist());

        manager[token][party.toAddress()] = allowed;
        emit UpdateHookManager(token, party.toAddress(), allowed);
    }

    /// @inheritdoc ITransferHook
    function updateRestriction(address token, bytes memory payload) external virtual auth {
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
    function freeze(address token, address user) public virtual authOrManager(token) {
        require(user != address(0), CannotFreezeZeroAddress());
        require(!root.endorsed(user) && !isEscrow(user), EndorsedUserCannotBeFrozen());
        require(!isShareClassVault(token, user), VaultCannotBeFrozen());

        _setHookBit(token, user, FREEZE_BIT, true);

        emit Freeze(token, user);
    }

    /// @inheritdoc IFreezable
    function unfreeze(address token, address user) public virtual authOrManager(token) {
        _setHookBit(token, user, FREEZE_BIT, false);

        emit Unfreeze(token, user);
    }

    /// @inheritdoc IMemberlist
    function updateMember(address token, address user, uint64 validUntil) public virtual authOrManager(token) {
        require(block.timestamp <= validUntil, InvalidValidUntil());
        require(!root.endorsed(user), EndorsedUserCannotBeUpdated());

        // Only the valid-until bits are replaced: the freeze bit and the bits a hook extension stores stay as they are.
        uint128 current = uint128(IShareToken(token).hookDataOf(user));
        uint128 hookData = (current & type(uint64).max) | (uint128(validUntil) << 64);
        IShareToken(token).setHookData(user, bytes16(hookData));

        emit UpdateMember(token, user, validUntil);
    }

    //----------------------------------------------------------------------------------------------
    // Callbacks
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

    /// @inheritdoc IRoleHook
    function onRoles(address token, RoleCheck[] calldata checks) external virtual returns (bytes4) {
        require(checkRoles(token, checks), TransferBlocked());
        return IRoleHook.onRoles.selector;
    }

    //----------------------------------------------------------------------------------------------
    // Decision
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc ITransferHook
    function checkERC20Transfer(address from, address to, uint256, HookData calldata hookData)
        public
        view
        virtual
        returns (bool)
    {
        return _decide(msg.sender, leg(from, to), from, to, hookData);
    }

    /// @inheritdoc IRoleHook
    function checkRoles(address token, RoleCheck[] calldata checks) public view virtual returns (bool) {
        for (uint256 i; i < checks.length; i++) {
            if (!checkRole(token, checks[i])) return false;
        }
        return true;
    }

    /// @inheritdoc IRoleHook
    /// @dev The reference hook limits no amount.
    function maxAllowed(address, RoleCheck[] calldata) external view virtual returns (uint256, uint256) {
        return (type(uint256).max, type(uint256).max);
    }

    /// @dev Whether `to` answers to `role` for value from `from` on `token`: the one check a batch is made of.
    ///      Override to add a rule on the check's `amount` and `effect`, such as a limit on `to`'s position.
    function checkRole(address token, RoleCheck calldata c) public view virtual returns (bool) {
        bytes16 fromData = c.from == address(0) ? bytes16(0) : IShareToken(token).hookDataOf(c.from);
        return _canHandOver(token, c.role, HookData(fromData, IShareToken(token).hookDataOf(c.to)), c.from, c.to);
    }

    /// @dev The decision on a share movement. `Fulfill` and `Burn` name no receiving side, so each checks only `from`;
    ///      `Transfer` and the default (`Mint`/`Release`) hand over to `to`, differing in the role it must answer to.
    ///      Override and call `super` to add a rule on a kind of movement.
    function _decide(address token, Kind kind, address from, address to, HookData memory data)
        internal
        view
        virtual
        returns (bool)
    {
        if (kind == Kind.Fulfill) return !_isBlocked(token, data.from, from);
        if (kind == Kind.Burn) return _qualifies(token, Role.Burn, data.from, from);
        if (kind == Kind.Transfer) return _canHandOver(token, Role.Transfer, data, from, to);
        return _canHandOver(token, Role.Entry, data, from, to);
    }

    /// @dev A hand-over: the source is not frozen and the destination answers to `role`. Override and call `super` to
    ///      add a rule between the two parties.
    function _canHandOver(address token, Role role, HookData memory data, address from, address to)
        internal
        view
        virtual
        returns (bool)
    {
        return !_isBlocked(token, data.from, from) && _qualifies(token, role, data.to, to);
    }

    /// @dev `user` is not frozen and answers to `role`: the role asks no membership (`Refund` never does, whatever the
    ///      policy mask holds), or `user` is a live member, an
    ///      escrow (as in a transfer, so a fund-of-funds payout into one passes) or, where the role takes or holds
    ///      shares, an endorsed contract. The roles that leave the pool refuse endorsed contracts: a public relay
    ///      would let anyone exit through it.
    function _qualifies(address token, Role role, bytes16 data, address user) internal view returns (bool) {
        if (_isBlocked(token, data, user)) return false;
        if (role == Role.Refund || policy >> uint8(role) & 1 == 0) return true;
        if (_validUntil(data) >= block.timestamp || isEscrow(user)) return true;
        return role <= Role.Transfer && root.endorsed(user);
    }

    /// @dev Frozen, from hook data already read: the bit is ignored on an escrow and on a vault of `token`'s own
    ///      share class.
    function _isBlocked(address token, bytes16 data, address user) internal view returns (bool) {
        return uint128(data).getBit(FREEZE_BIT) && !(isEscrow(user) || isShareClassVault(token, user));
    }

    function _validUntil(bytes16 data) internal pure returns (uint64) {
        return uint64(uint128(data) >> 64);
    }

    //----------------------------------------------------------------------------------------------
    // Views
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IShareTokenHook
    function leg(address from, address to) public view virtual returns (Kind) {
        if (from == address(0) && to != crosschainSource && !isEscrow(to)) return Kind.Mint;
        if (to != address(0) && isEscrow(from)) return Kind.Release;
        if (to == address(0)) {
            if (from == address(spoke)) return Kind.Fulfill;
            if (from != crosschainSource) return Kind.Burn;
        }
        return Kind.Transfer;
    }

    /// @inheritdoc IShareTokenHook
    function isEscrow(address addr) public view virtual returns (bool) {
        return !escrowProvider.poolId(addr).isNull();
    }

    /// @inheritdoc IShareTokenHook
    function isShareClassVault(address token, address addr) public view virtual returns (bool) {
        VaultDetails memory details = spokeRegistry.vaultDetails(addr);
        return details.isLinked && address(spokeRegistry.shareToken(details.poolId, details.scId)) == token;
    }

    /// @inheritdoc IFreezable
    function isFrozen(address token, address user) external view virtual returns (bool) {
        return _getHookBit(token, user, FREEZE_BIT);
    }

    /// @inheritdoc IMemberlist
    function isMember(address token, address user) external view virtual returns (bool isValid, uint64 validUntil) {
        validUntil = _validUntil(IShareToken(token).hookDataOf(user));
        isValid = validUntil >= block.timestamp;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) external pure virtual override returns (bool) {
        return interfaceId == type(ITransferHook).interfaceId || interfaceId == type(IRoleHook).interfaceId
            || interfaceId == type(IERC165).interfaceId;
    }

    //----------------------------------------------------------------------------------------------
    // Hook data
    //----------------------------------------------------------------------------------------------

    /// @dev Sets one flag of `user`'s hook data and keeps every other bit. Only bits 0 to 63 are reachable: the
    ///      valid-until bits above them belong to `updateMember`. Bit 0 is the freeze flag, so a hook extension
    ///      keeps its own flags in bits 1 to 63. The caller authorises the change and emits its own event.
    function _setHookBit(address token, address user, uint8 bit, bool value) internal {
        require(bit < 64, InvalidHookBit());

        uint128 hookData = uint128(IShareToken(token).hookDataOf(user));
        IShareToken(token).setHookData(user, bytes16(uint128(hookData.withBit(bit, value))));
    }

    /// @dev One flag of `user`'s hook data, from bit 0 (the freeze flag) to bit 63.
    function _getHookBit(address token, address user, uint8 bit) internal view returns (bool) {
        require(bit < 64, InvalidHookBit());

        return uint128(IShareToken(token).hookDataOf(user)).getBit(bit);
    }
}
