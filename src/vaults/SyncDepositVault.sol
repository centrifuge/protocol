// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault, AsyncRedeemVault, AbstractSyncDepositVault} from "src/vaults/BaseVaults.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {ISyncManager} from "src/vaults/interfaces/investments/ISyncManager.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

/// @title  SyncDepositVault
/// @notice Partially (a)synchronous Tokenized Vault implementation with synchronous deposits and asynchronous
/// redemptions following ERC-7540.
///
/// @dev    Each vault issues shares of Centrifuge tranches as restricted ERC-20 or ERC-6909 tokens
///         against asset deposits based on the current share price.
contract SyncDepositVault is AbstractSyncDepositVault, AsyncRedeemVault {
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
        BaseVault(poolId_, trancheId_, asset_, tokenId_, share_, root_, syncDepositManager_)
        AbstractSyncDepositVault(syncDepositManager_)
        AsyncRedeemVault(asyncRedeemManager_)
    {}

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(AsyncRedeemVault, AbstractSyncDepositVault)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
