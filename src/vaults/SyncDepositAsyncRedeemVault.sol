// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault} from "src/vaults/BaseVault.sol";
import {AsyncRedeemVault} from "src/vaults/AsyncRedeemVault.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {ISyncInvestmentManager} from "src/vaults/interfaces/investments/ISyncInvestmentManager.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

/// @title  SyncDepositAsyncRedeemVault
/// @notice TODO
contract SyncDepositAsyncRedeemVault is AsyncRedeemVault {
    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        uint256 tokenId_,
        address share_,
        address root_,
        address syncDepositManager_,
        address asyncRedeemManager_
    )
        AsyncRedeemVault(poolId_, trancheId_, asset_, tokenId_, share_, root_, syncDepositManager_, asyncRedeemManager_)
    {}

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        maxAssets = syncInvestmentManager().maxDeposit(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        shares = syncInvestmentManager().previewDeposit(address(this), msg.sender, assets);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncInvestmentManager().escrow(), assets);
        shares = syncInvestmentManager().deposit(address(this), assets, receiver, msg.sender);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxMint(address owner) public view returns (uint256 maxShares) {
        maxShares = syncInvestmentManager().maxMint(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256 shares) external view returns (uint256 assets) {
        assets = syncInvestmentManager().previewMint(address(this), msg.sender, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = syncInvestmentManager().mint(address(this), shares, receiver, msg.sender);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncInvestmentManager().escrow(), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @dev Strongly-typed accessor to the generic base manager
    function syncInvestmentManager() public view returns (ISyncInvestmentManager) {
        return ISyncInvestmentManager(address(IBaseVault(address(this)).manager()));
    }
}
