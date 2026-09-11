// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseSyncDepositVault} from "./BaseVaults.sol";
import {IBaseVault} from "./interfaces/IBaseVault.sol";
import {IAsyncVault} from "./interfaces/IAsyncVault.sol";
import {IVaultRouter} from "./interfaces/IVaultRouter.sol";

import {Auth} from "../misc/Auth.sol";
import {Multicall} from "../misc/Multicall.sol";
import {Recoverable} from "../misc/Recoverable.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";
import {IERC7540Deposit} from "../misc/interfaces/IERC7540.sol";
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
///         message. Investment requests are paid for by the pool through the request manager, so the caller
///         should not attach native tokens for them: any value sent for such a call stays in the router
///         and is only recoverable via `Recoverable`.
/// @dev    It is critical to ensure that at the end of any transaction, no funds remain in the
///         VaultRouter. Any funds that do remain are at risk of being taken by other users.
contract VaultRouter is Multicall, Recoverable, IVaultRouter {
    using CastLib for address;

    /// @dev Requests for Centrifuge pool are non-fungible and all have ID = 0
    uint256 private constant REQUEST_ID = 0;

    ISpoke public immutable spoke;
    ISpokeRegistry public immutable spokeRegistry;

    constructor(ISpoke spoke_, ISpokeRegistry spokeRegistry_, address deployer) Auth(deployer) {
        spoke = spoke_;
        spokeRegistry = spokeRegistry_;
    }

    //----------------------------------------------------------------------------------------------
    // Enable interactions
    //----------------------------------------------------------------------------------------------

    function enable(IBaseVault vault) public payable protected {
        vault.setEndorsedOperator(msg.sender, true);
    }

    function disable(IBaseVault vault) external payable protected {
        vault.setEndorsedOperator(msg.sender, false);
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

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault));
        require(vaultDetails.asset != address(0), ISpokeRegistry.UnknownVault());
        if (owner == address(this)) {
            _approveMax(vaultDetails.asset, address(vault));
        }

        vault.requestDeposit(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function deposit(BaseSyncDepositVault vault, uint256 assets, address receiver, address owner)
        external
        payable
        protected
    {
        require(owner == msg.sender || owner == address(this), InvalidOwner());
        require(!vault.supportsInterface(type(IERC7540Deposit).interfaceId), NonSyncDepositVault());

        VaultDetails memory vaultDetails = spokeRegistry.vaultDetails(address(vault));
        require(vaultDetails.asset != address(0), ISpokeRegistry.UnknownVault());
        if (owner != address(this)) SafeTransferLib.safeTransferFrom(vaultDetails.asset, owner, address(this), assets);
        _approveMax(vaultDetails.asset, address(vault));

        vault.deposit(assets, receiver);
    }

    /// @inheritdoc IVaultRouter
    function crosschainTransferShares(
        BaseSyncDepositVault vault,
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

    /// @inheritdoc IVaultRouter
    function claimDeposit(IAsyncVault vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxMint = vault.maxMint(controller);
        vault.mint(maxMint, receiver, controller);
    }

    /// @inheritdoc IVaultRouter
    function cancelDepositRequest(IAsyncVault vault) external payable protected {
        vault.cancelDepositRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimCancelDepositRequest(IAsyncVault vault, address receiver, address controller)
        external
        payable
        protected
    {
        _canClaim(vault, receiver, controller);
        vault.claimCancelDepositRequest(REQUEST_ID, receiver, controller);
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
        vault.requestRedeem(amount, controller, owner);
    }

    /// @inheritdoc IVaultRouter
    function claimRedeem(IBaseVault vault, address receiver, address controller) external payable protected {
        _canClaim(vault, receiver, controller);
        uint256 maxWithdraw = vault.maxWithdraw(controller);
        vault.withdraw(maxWithdraw, receiver, controller);
    }

    /// @inheritdoc IVaultRouter
    function cancelRedeemRequest(IAsyncVault vault) external payable protected {
        vault.cancelRedeemRequest(REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IVaultRouter
    function claimCancelRedeemRequest(IAsyncVault vault, address receiver, address controller)
        external
        payable
        protected
    {
        _canClaim(vault, receiver, controller);
        vault.claimCancelRedeemRequest(REQUEST_ID, receiver, controller);
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
    function getVault(PoolId poolId, ShareClassId scId, address asset) external view returns (address) {
        IShareToken share = IShareToken(address(spokeRegistry.shareToken(poolId, scId)));
        require(address(share) != address(0), ISpokeRegistry.ShareTokenDoesNotExist());
        return share.vault(asset);
    }

    /// @inheritdoc IVaultRouter
    function hasPermissions(IBaseVault vault, address controller) external view returns (bool) {
        return vault.isPermissioned(controller);
    }

    /// @inheritdoc IVaultRouter
    function isEnabled(IBaseVault vault, address controller) public view returns (bool) {
        return vault.isOperator(controller, address(this));
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
    function _canClaim(IBaseVault vault, address receiver, address controller) internal view {
        require(controller == msg.sender || (controller == receiver && isEnabled(vault, controller)), InvalidSender());
    }
}
