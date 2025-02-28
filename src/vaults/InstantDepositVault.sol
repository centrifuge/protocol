// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault} from "src/vaults/BaseVault.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";
import "src/misc/interfaces/IERC20.sol";

interface IInstantManager {
    function escrow() external view returns (address);
    function maxDeposit(address vault, address owner) external view returns (uint256);
    function previewDeposit(address vault, address sender, uint256 assets) external view returns (uint256);
    function deposit(address vault, uint256 assets, address receiver, address owner) external view returns (uint256);
    function maxMint(address vault, address owner) external view returns (uint256);
    function previewMint(address vault, address sender, uint256 shares) external view returns (uint256);
    function mint(address vault, uint256 shares, address receiver, address owner) external view returns (uint256);
}

/// @title  InstantDepositVault
/// @notice TODO
contract InstantDepositVault is BaseVault {
    IInstantManager public instantManager;

    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        address share_,
        address root_,
        address manager_,
        address instantManager_
    ) BaseVault(poolId_, trancheId_, asset_, share_, root_, manager_) {
        instantManager = IInstantManager(instantManager_);
    }

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        maxAssets = instantManager.maxDeposit(address(this), owner);
    }

    function previewDeposit(uint256 assets) external view returns (uint256 shares) {
        shares = instantManager.previewDeposit(address(this), msg.sender, assets);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        SafeTransferLib.safeTransferFrom(asset, msg.sender, instantManager.escrow(), assets);
        shares = instantManager.deposit(address(this), assets, receiver, msg.sender);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxMint(address owner) public view returns (uint256 maxShares) {
        maxShares = instantManager.maxMint(address(this), owner);
    }

    function previewMint(uint256 shares) external view returns (uint256 assets) {
        assets = instantManager.previewMint(address(this), msg.sender, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = instantManager.mint(address(this), shares, receiver, msg.sender);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, instantManager.escrow(), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public pure override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
