// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {IERC6909} from "src/misc/interfaces/IERC6909.sol";
import {IERC20} from "src/misc/interfaces/IERC20.sol";

import {BaseVault, AsyncRedeemVault} from "src/vaults/BaseVaults.sol";
import {IAsyncManager} from "src/vaults/interfaces/investments/IAsyncManager.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

/// @title  AsyncVault
/// @notice Asynchronous Tokenized Vault standard implementation for Centrifuge pools
///
/// @dev    Each vault issues shares of Centrifuge tranches as restricted ERC-20 or ERC-6909 tokens
///         against asset deposits based on the current share price.
///
///         ERC-7540 is an extension of the ERC-4626 standard by 'requestDeposit' & 'requestRedeem' methods, where
///         deposit and redeem orders are submitted to the pools to be included in the execution of the following epoch.
///         After execution users can use the deposit, mint, redeem and withdraw functions to get their shares
///         and/or assets from the pools.
contract AsyncVault is AsyncRedeemVault, IAsyncVault {
    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        uint256 tokenId_,
        address share_,
        address root_,
        address manager_
    ) BaseVault(poolId_, trancheId_, asset_, tokenId_, share_, root_, manager_) AsyncRedeemVault(manager_) {}

    // --- ERC-7540 methods ---
    /// @inheritdoc IERC7540Deposit
    function requestDeposit(uint256 assets, address controller, address owner) public returns (uint256) {
        require(owner == msg.sender || isOperator[owner][msg.sender], "AsyncVault/invalid-owner");
        require(
            tokenId == 0 && IERC20(asset).balanceOf(owner) >= assets
                || tokenId > 0 && IERC6909(asset).balanceOf(owner, tokenId) >= assets,
            "AsyncVault/insufficient-balance"
        );

        require(
            asyncManager().requestDeposit(address(this), assets, controller, owner, msg.sender),
            "AsyncVault/request-deposit-failed"
        );

        if (tokenId == 0) {
            SafeTransferLib.safeTransferFrom(asset, owner, asyncManager().escrow(), assets);
        } else {
            IERC6909(asset).transferFrom(owner, asyncManager().escrow(), tokenId, assets);
        }

        emit DepositRequest(controller, owner, REQUEST_ID, msg.sender, assets);
        return REQUEST_ID;
    }

    /// @inheritdoc IERC7540Deposit
    function pendingDepositRequest(uint256, address controller) public view returns (uint256 pendingAssets) {
        pendingAssets = asyncManager().pendingDepositRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540Deposit
    function claimableDepositRequest(uint256, address controller) external view returns (uint256 claimableAssets) {
        claimableAssets = maxDeposit(controller);
    }

    // --- Asynchronous cancellation methods ---
    /// @inheritdoc IERC7540CancelDeposit
    function cancelDepositRequest(uint256, address controller) external {
        _validateController(controller);
        asyncManager().cancelDepositRequest(address(this), controller, msg.sender);
        emit CancelDepositRequest(controller, REQUEST_ID, msg.sender);
    }

    /// @inheritdoc IERC7540CancelDeposit
    function pendingCancelDepositRequest(uint256, address controller) public view returns (bool isPending) {
        isPending = asyncManager().pendingCancelDepositRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelDeposit
    function claimableCancelDepositRequest(uint256, address controller) public view returns (uint256 claimableAssets) {
        claimableAssets = asyncManager().claimableCancelDepositRequest(address(this), controller);
    }

    /// @inheritdoc IERC7540CancelDeposit
    function claimCancelDepositRequest(uint256, address receiver, address controller)
        external
        returns (uint256 assets)
    {
        _validateController(controller);
        assets = asyncManager().claimCancelDepositRequest(address(this), receiver, controller);
        emit CancelDepositClaim(controller, receiver, REQUEST_ID, msg.sender, assets);
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override(AsyncRedeemVault, IERC165) returns (bool) {
        return interfaceId == type(IERC7540Deposit).interfaceId
            || interfaceId == type(IERC7540CancelDeposit).interfaceId || interfaceId == type(IAsyncRedeemVault).interfaceId
            || super.supportsInterface(interfaceId);
    }

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function maxDeposit(address controller) public view returns (uint256 maxAssets) {
        maxAssets = asyncManager().maxDeposit(address(this), controller);
    }

    /// @inheritdoc IERC7540Deposit
    function deposit(uint256 assets, address receiver, address controller) public returns (uint256 shares) {
        _validateController(controller);
        shares = asyncManager().deposit(address(this), assets, receiver, controller);
        emit Deposit(receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    /// @notice     When claiming deposit requests using deposit(), there can be some precision loss leading to dust.
    ///             It is recommended to use mint() to claim deposit requests instead.
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = deposit(assets, receiver, msg.sender);
    }

    /// @inheritdoc IERC7575
    function maxMint(address controller) public view returns (uint256 maxShares) {
        maxShares = asyncManager().maxMint(address(this), controller);
    }

    /// @inheritdoc IERC7540Deposit
    function mint(uint256 shares, address receiver, address controller) public returns (uint256 assets) {
        _validateController(controller);
        assets = asyncManager().mint(address(this), shares, receiver, controller);
        emit Deposit(receiver, controller, assets, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = mint(shares, receiver, msg.sender);
    }

    /// @dev Strongly-typed accessor to the generic async redeem manager
    function asyncManager() public view returns (IAsyncManager) {
        return IAsyncManager(address(IAsyncRedeemVault(address(this)).asyncRedeemManager()));
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewDeposit(uint256) external pure returns (uint256) {
        revert();
    }

    /// @dev Preview functions for ERC-7540 vaults revert
    function previewMint(uint256) external pure returns (uint256) {
        revert();
    }

    // --- Event emitters ---
    function onDepositClaimable(address controller, uint256 assets, uint256 shares) public auth {
        emit DepositClaimable(controller, REQUEST_ID, assets, shares);
    }

    function onCancelDepositClaimable(address controller, uint256 assets) public auth {
        emit CancelDepositClaimable(controller, REQUEST_ID, assets);
    }
}
