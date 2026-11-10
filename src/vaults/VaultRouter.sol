// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IAsyncVault} from "./interfaces/IAsyncVault.sol";
import {IVaultRouter} from "./interfaces/IVaultRouter.sol";
import {VaultActionLib, VaultActionKind, VaultAction} from "./libraries/VaultActionLib.sol";

import {Auth} from "../misc/Auth.sol";
import {Multicall} from "../misc/Multicall.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {MathLib} from "../misc/libraries/MathLib.sol";
import {IMulticall} from "../misc/interfaces/IMulticall.sol";
import {IERC20, IERC20Permit} from "../misc/interfaces/IERC20.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../core/types/PoolId.sol";
import {ISpoke} from "../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../core/types/ShareClassId.sol";
import {VaultDetails, ISpokeRegistry} from "../core/spoke/interfaces/ISpokeRegistry.sol";

import {IShareToken} from "../token/interfaces/IShareToken.sol";

/// @title  VaultRouter
/// @notice This is a helper contract, designed to be the entrypoint for EOAs.
///         It removes the need to know about all other contracts and simplifies the way to interact with the protocol.
///         It bundles several calls into one transaction via multicall, each dispatching its own cross-chain
///         message. Investment requests are paid for by the pool through the vault's request router, so the
///         caller should not attach native tokens for them: any value sent for such a call stays in the router
///         and is only recoverable via `Recoverable`.
/// @dev    It is critical to ensure that at the end of any transaction, no funds remain in the
///         VaultRouter. Any funds that do remain are at risk of being taken by other users.
contract VaultRouter is Multicall, Recoverable, IVaultRouter {
    ISpoke public immutable spoke;
    ISpokeRegistry public immutable spokeRegistry;

    bool private transient _inBatch;
    bool private transient _valueSpent;

    constructor(ISpoke spoke_, ISpokeRegistry spokeRegistry_, address deployer) Auth(deployer) {
        spoke = spoke_;
        spokeRegistry = spokeRegistry_;
    }

    /// @dev A multicall gives every call the same `msg.value`, so the value a batch carries funds one bridge transfer.
    function multicall(bytes[] calldata data) public payable override(IMulticall, Multicall) {
        // A nested multicall must not end the batch it runs in, or the outer calls could spend the value again.
        bool outermost = !_inBatch;
        _inBatch = true;
        super.multicall(data);
        if (outermost) {
            _inBatch = false;
            _valueSpent = false;
        }
    }

    //----------------------------------------------------------------------------------------------
    // Deposit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function requestDeposit(IAsyncVault vault, uint256 amount, address controller, address owner)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        // The router is a public relay and an investor's operator, so a request it relayed for another controller
        // would pass the vault's check as that controller's own, with no consent from them.
        require(controller == msg.sender, InvalidController());

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault));
        require(vaultDetails.asset != address(0), ISpokeRegistry.UnknownVault());
        if (owner == address(this)) _approveMax(vaultDetails.asset, address(vault));

        vault.requestDeposit(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function deposit(IAsyncVault vault, uint256 assets, address receiver, address owner) external payable protected {
        require(owner == msg.sender || owner == address(this), InvalidOwner());

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault));
        require(vaultDetails.asset != address(0), ISpokeRegistry.UnknownVault());
        _requirePayer(vault, receiver, assets);
        if (owner != address(this)) SafeTransferLib.safeTransferFrom(vaultDetails.asset, owner, address(this), assets);
        _approveMax(vaultDetails.asset, address(vault));

        vault.deposit(assets, receiver);
    }

    /// @inheritdoc IVaultRouter
    function claimDeposit(IAsyncVault vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        vault.mint(vault.maxMint(controller), receiver, controller);
    }

    //----------------------------------------------------------------------------------------------
    // Redeem
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function requestRedeem(IAsyncVault vault, uint256 amount, address controller, address owner)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        require(controller == msg.sender, InvalidController());
        vault.requestRedeem(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function claimRedeem(IAsyncVault vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        vault.withdraw(vault.maxWithdraw(controller), receiver, controller);
    }

    //----------------------------------------------------------------------------------------------
    // Cross-chain transfers
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function crosschainTransferShares(
        IAsyncVault vault,
        uint128 shares,
        uint16 centrifugeId,
        bytes32 receiver,
        address owner,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) external payable protected {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        require(spokeRegistry.isVaultRegistered(address(vault)), ISpokeRegistry.UnknownVault());

        address share_ = vault.share();
        if (owner != address(this)) SafeTransferLib.safeTransferFrom(share_, owner, address(this), shares);
        _approveMax(share_, address(spoke));
        _crosschainTransferShares(
            spokeRegistry.vaultDetails(address(vault)),
            shares,
            centrifugeId,
            receiver,
            owner,
            extraGasLimit,
            remoteExtraGasLimit,
            refund
        );
    }

    /// @dev Split out of {crosschainTransferShares} to avoid a stack-too-deep: the outer frame holds
    ///      eight parameters plus the vault-validity check, which together exceed the stack limit.
    function _crosschainTransferShares(
        VaultDetails memory vaultDetails,
        uint128 shares,
        uint16 centrifugeId,
        bytes32 receiver,
        address owner,
        uint128 extraGasLimit,
        uint128 remoteExtraGasLimit,
        address refund
    ) internal {
        if (_inBatch && msg.value != 0) {
            require(!_valueSpent, ValueAlreadySpent());
            _valueSpent = true;
        }

        spoke.crosschainTransferShares{value: msg.value}(
            centrifugeId,
            vaultDetails.poolId,
            vaultDetails.scId,
            receiver,
            owner,
            address(this),
            shares,
            extraGasLimit,
            remoteExtraGasLimit,
            refund
        );
    }

    //----------------------------------------------------------------------------------------------
    // ERC-20 permits
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function permit(address asset, address spender, uint256 assets, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        payable
        protected
    {
        try IERC20Permit(asset).permit(msg.sender, spender, assets, deadline, v, r, s) {} catch {}
    }

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IVaultRouter
    function getVault(PoolId poolId, ShareClassId scId, address asset) external view returns (address vault_) {
        IShareToken share = IShareToken(address(spokeRegistry.shareToken(poolId, scId)));
        require(address(share) != address(0), ISpokeRegistry.ShareTokenDoesNotExist());

        vault_ = share.vault(asset);
        if (vault_ == address(0)) return address(0);

        VaultDetails memory details = spokeRegistry.vaultDetails(vault_);
        require(
            details.isLinked && details.poolId == poolId && details.scId == scId && details.asset == asset
                && details.tokenId == 0,
            ISpokeRegistry.InvalidVault()
        );
    }

    /// @inheritdoc IVaultRouter
    function isEnabled(IAsyncVault vault, address controller) public view returns (bool) {
        return vault.isOperator(controller, address(this));
    }

    //----------------------------------------------------------------------------------------------
    // Internal methods
    //----------------------------------------------------------------------------------------------

    /// @dev The vault sees the router as the depositor, and the router is endorsed, so the share hook's instant
    ///      deposit check would pass whoever pays. The router asks it for the caller, as a direct deposit would be.
    ///      The shares are the vault's own quote, net of the spread, as the vault's check carries them.
    function _requirePayer(IAsyncVault vault, address receiver, uint256 assets) internal view {
        uint128 shares = MathLib.toUint128(vault.previewDeposit(assets));
        require(
            VaultActionLib.check(
                vault.share(),
                VaultAction(
                    VaultActionKind.InstantDeposit, msg.sender, msg.sender, receiver, MathLib.toUint128(assets), shares
                )
            ),
            InvalidSender()
        );
    }

    /// @notice Gives the max approval to `to` for spending the given `asset` if not already approved.
    /// @dev    Assumes that `type(uint256).max` is large enough to never have to increase the allowance again.
    function _approveMax(address asset, address spender) internal {
        if (IERC20(asset).allowance(address(this), spender) == 0) {
            SafeTransferLib.safeApprove(asset, spender, type(uint256).max);
        }
    }

    /// @notice Ensures msg.sender is either the controller, or can permissionlessly claim
    ///         on behalf of the controller.
    function _canClaim(IAsyncVault vault, address receiver, address controller) internal view {
        require(controller == msg.sender || (controller == receiver && isEnabled(vault, controller)), InvalidSender());
    }
}
