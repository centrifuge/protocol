// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {AsyncRedeemVault} from "src/vaults/AsyncRedeemVault.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {ISyncDepositAsyncRedeemManager} from "src/vaults/interfaces/investments/ISyncDepositAsyncRedeemManager.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

/// @title  SyncDepositVault
/// @notice TODO
contract SyncDepositVault is AsyncRedeemVault {
    ISyncDepositAsyncRedeemManager public syncInvestAsyncRedeemManager;

    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        uint256 tokenId_,
        address share_,
        address root_,
        address manager_,
        address syncInvestAsyncRedeemManager_
    ) AsyncRedeemVault(poolId_, trancheId_, asset_, tokenId_, share_, root_, manager_) {
        syncInvestAsyncRedeemManager = ISyncDepositAsyncRedeemManager(syncInvestAsyncRedeemManager_);
    }

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        maxAssets = syncInvestAsyncRedeemManager.maxDeposit(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        shares = syncInvestAsyncRedeemManager.previewDeposit(address(this), msg.sender, assets);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncInvestAsyncRedeemManager.escrow(), assets);
        shares = syncInvestAsyncRedeemManager.deposit(address(this), assets, receiver, msg.sender);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxMint(address owner) public view returns (uint256 maxShares) {
        maxShares = syncInvestAsyncRedeemManager.maxMint(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256 shares) external view returns (uint256 assets) {
        assets = syncInvestAsyncRedeemManager.previewMint(address(this), msg.sender, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = syncInvestAsyncRedeemManager.mint(address(this), shares, receiver, msg.sender);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncInvestAsyncRedeemManager.escrow(), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
