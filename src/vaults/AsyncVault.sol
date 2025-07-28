// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault} from "./BaseVaults.sol";
import {BaseAsyncRedeemVault} from "./BaseVaults.sol";
import {IAsyncVault} from "./interfaces/IAsyncVault.sol";
import {IAsyncRequestManager} from "./interfaces/IVaultManagers.sol";

import "../misc/interfaces/IERC7540.sol";
import "../misc/interfaces/IERC7575.sol";
import {IERC20} from "../misc/interfaces/IERC20.sol";
import {SafeTransferLib} from "../misc/libraries/SafeTransferLib.sol";

import {PoolId} from "../common/types/PoolId.sol";
import {ShareClassId} from "../common/types/ShareClassId.sol";

import {VaultKind} from "../spoke/interfaces/IVault.sol";
import {IShareToken} from "../spoke/interfaces/IShareToken.sol";

/// @title  AsyncVault
/// @notice Asynchronous Tokenized Vault standard implementation for Centrifuge pools
///
/// @dev    Each vault issues shares of Centrifuge share class tokens as restricted ERC-20 tokens
///         against asset deposits based on the current share price.
///
///         ERC-7540 is an extension of the ERC-4626 standard by 'requestDeposit' & 'requestRedeem' methods, where
///         deposit and redeem orders are submitted to the pools to be included in the execution of the following epoch.
///         After execution users can use the deposit, mint, redeem and withdraw functions to get their shares
///         and/or assets from the pools.
contract AsyncVault is BaseAsyncRedeemVault, IAsyncVault {
    constructor(
        PoolId poolId_,
        ShareClassId scId_,
        address asset_,
        IShareToken token_,
        address root_,
        IAsyncRequestManager manager_
    ) BaseVault(poolId_, scId_, asset_, token_, root_, manager_) BaseAsyncRedeemVault(manager_) {}

    //----------------------------------------------------------------------------------------------
    // ERC-7540 deposit
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7540Deposit
    function requestDeposit(uint256 assets, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender || isOperator[owner][msg.sender], InvalidOwner());
        require(IERC20(asset).balanceOf(owner) >= assets, InsufficientBalance());

        require(asyncManager().requestDeposit(this, assets, controller, owner, msg.sender), RequestDepositFailed());
        SafeTransferLib.safeTransferFrom(asset, owner, address(baseManager.globalEscrow()), assets);

        emit DepositRequest(controller, owner, REQUEST_ID, msg.sender, assets);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256, address controller) public view returns (uint256 pendingAssets) {
        pendingAssets = asyncManager().pendingDepositRequest(this, controller);
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 claimableAssets) {
        claimableAssets = maxDeposit(controller);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7887
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7887Deposit
    function cancelDepositRequest(uint256, address controller) external {
        _validateController(controller);
        asyncManager().cancelDepositRequest(this, controller, msg.sender);
        emit CancelDepositRequest(controller, REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IERC7887Deposit
    function pendingCancelDepositRequest(uint256, address controller) public view returns (bool isPending) {
        isPending = asyncManager().pendingCancelDepositRequest(this, controller);
    }

    /// @inheritdoc IERC7887Deposit
    function claimableCancelDepositRequest(uint256, address controller) public view returns (uint256 claimableAssets) {
        claimableAssets = asyncManager().claimableCancelDepositRequest(this, controller);
    }

    /// @inheritdoc IERC7887Deposit
    function claimCancelDepositRequest(uint256, address receiver, address controller)
        external
        returns (uint256 assets)
    {
        _validateController(controller);
        assets = asyncManager().claimCancelDepositRequest(this, receiver, controller);
        emit CancelDepositClaim(controller, receiver, REQUEST_ID, msg.sender, assets);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override(BaseAsyncRedeemVault, IERC165) returns (bool) {
        return interfaceId == type(IERC7540Deposit).interfaceId || interfaceId == type(IERC7887Deposit).interfaceId
            || super.supportsInterface(interfaceId);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-7540 claim
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC7575
    function maxDeposit(address controller) public view returns (uint256 maxAssets) {
        maxAssets = asyncManager().maxDeposit(this, controller);
    }

    /// @inheritdoc IERC7540Deposit
    function deposit(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _validateController(controller);
        shares = asyncManager().deposit(this, assets, receiver, controller);
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @inheritdoc IERC7575
    /// @notice     When claiming deposit requests using deposit(), there can be some precision loss leading to dust.
    ///             It is recommended to use mint() to claim deposit requests instead.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = deposit(assets, receiver, msg.sender);
    }

    /// @inheritdoc IERC7575
    function maxMint(address controller) public view returns (uint256 maxShares) {
        maxShares = asyncManager().maxMint(this, controller);
    }

    /// @inheritdoc IERC7540Deposit
    function mint(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        _validateController(controller);
        assets = asyncManager().mint(this, shares, receiver, controller);
        emit Deposit(controller, receiver, assets, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = mint(shares, receiver, msg.sender);
    }

    /// @dev Strongly-typed accessor to the generic async redeem manager
    function asyncManager() public view returns (IAsyncRequestManager) {
        return IAsyncRequestManager(address(asyncRedeemManager));
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewDeposit(uint256) external pure returns (uint256) {
        revert();
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewMint(uint256) external pure returns (uint256) {
        revert();
    }

    //----------------------------------------------------------------------------------------------
    // Event emitters
    //----------------------------------------------------------------------------------------------

    function onDepositClaimable(address controller, uint256 assets, uint256 shares) public virtual auth {
        emit DepositClaimable(controller, REQUEST_ID, assets, shares);
    }

    function onCancelDepositClaimable(address controller, uint256 assets) public virtual auth {
        emit CancelDepositClaimable(controller, REQUEST_ID, assets);
    }

    //----------------------------------------------------------------------------------------------
    // IBaseVault view
    //----------------------------------------------------------------------------------------------

    function vaultKind() public pure returns (VaultKind vaultKind_) {
        return VaultKind.Async;
    }
}
