// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault} from "src/vaults/BaseVault.sol";
import {AsyncRedeemVault} from "src/vaults/AsyncRedeemVault.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {ISyncDepositAsyncRedeemManager} from "src/vaults/interfaces/investments/ISyncDepositAsyncRedeemManager.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

/// @title  SyncDepositVault
/// @notice TODO
contract SyncDepositVault is AsyncRedeemVault {
    constructor(
        uint64 poolId_,
        bytes16 trancheId_,
        address asset_,
        uint256 tokenId_,
        address share_,
        address root_,
        address manager_
    ) AsyncRedeemVault(poolId_, trancheId_, asset_, tokenId_, share_, root_, manager_) {}

    // --- ERC-4626 methods ---
    /// @inheritdoc IERC7575
    function maxDeposit(address owner) public view returns (uint256 maxAssets) {
        maxAssets = syncDepositAsyncRedeemManager().maxDeposit(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewDeposit(uint256 assets) external view override returns (uint256 shares) {
        shares = syncDepositAsyncRedeemManager().previewDeposit(address(this), msg.sender, assets);
    }

    /// @inheritdoc IERC7575
    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncDepositAsyncRedeemManager().escrow(), assets);
        shares = syncDepositAsyncRedeemManager().deposit(address(this), assets, receiver, msg.sender);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    /// @inheritdoc IERC7575
    function maxMint(address owner) public view returns (uint256 maxShares) {
        maxShares = syncDepositAsyncRedeemManager().maxMint(address(this), owner);
    }

    /// @inheritdoc IERC7575
    function previewMint(uint256 shares) external view returns (uint256 assets) {
        assets = syncDepositAsyncRedeemManager().previewMint(address(this), msg.sender, shares);
    }

    /// @inheritdoc IERC7575
    function mint(uint256 shares, address receiver) public returns (uint256 assets) {
        assets = syncDepositAsyncRedeemManager().mint(address(this), shares, receiver, msg.sender);
        SafeTransferLib.safeTransferFrom(asset, msg.sender, syncDepositAsyncRedeemManager().escrow(), assets);
        emit Deposit(receiver, msg.sender, assets, shares);
    }

    // --- ERC165 support ---
    /// @inheritdoc IERC165
    // TODOL Remove if not customized
    function supportsInterface(bytes4 interfaceId) public pure override(BaseVault, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    /// @dev Strongly-typed accessor to the generic base manager
    function syncDepositAsyncRedeemManager() public view returns (ISyncDepositAsyncRedeemManager) {
        return ISyncDepositAsyncRedeemManager(IBaseVault(address(this)).manager());
    }
}
