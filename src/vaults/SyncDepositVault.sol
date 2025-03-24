// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault} from "src/vaults/BaseVault.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {ISyncInvestmentManager} from "src/vaults/interfaces/ISyncInvestmentManager.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";
import "src/misc/interfaces/IERC20.sol";

/// @title  SyncDepositVault
/// @notice TODO
contract SyncDepositVault is BaseVault {
    ISyncInvestmentManager public syncInvestManager;

    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        uint256 tokenId_,
        address share_,
        address root_,
        address manager_,
        address syncInvestManager_
    ) BaseVault(poolId_, trancheId_, asset_, tokenId_, share_, root_, manager_) {
        syncInvestManager = ISyncInvestmentManager(syncInvestManager_);
    }

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        maxAssets = syncInvestManager.maxDeposit(address(this), owner);
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        shares = syncInvestManager.previewDeposit(address(this), msg.sender, assets);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncInvestManager.escrow(), assets);
        shares = syncInvestManager.deposit(address(this), assets, receiver, msg.sender);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxMint(address owner) public view returns (uint256 maxShares) {
        maxShares = syncInvestManager.maxMint(address(this), owner);
    }

    function previewMint(uint256 shares) external view returns (uint256 assets) {
        assets = syncInvestManager.previewMint(address(this), msg.sender, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = syncInvestManager.mint(address(this), shares, receiver, msg.sender);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncInvestManager.escrow(), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
