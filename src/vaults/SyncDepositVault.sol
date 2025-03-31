// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {BaseVault, AsyncRedeemVault, BaseSyncDepositVault} from "src/vaults/BaseVaults.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";
import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import "src/vaults/interfaces/IERC7540.sol";
import "src/vaults/interfaces/IERC7575.sol";

/// @title  SyncDepositVault
/// @notice Partially (a)synchronous Tokenized Vault implementation with synchronous deposits and asynchronous
/// redemptions following ERC-7540.
///
/// @dev    Each vault issues shares of Centrifuge tranches as restricted ERC-20 or ERC-6909 tokens
///         against asset deposits based on the current share price.
contract SyncDepositVault is BaseSyncDepositVault, AsyncRedeemVault {
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
        BaseSyncDepositVault(syncDepositManager_)
        AsyncRedeemVault(asyncRedeemManager_)
    {}

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(AsyncRedeemVault, BaseSyncDepositVault)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
