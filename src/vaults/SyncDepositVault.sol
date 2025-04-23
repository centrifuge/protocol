// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import "src/misc/interfaces/IERC7540.sol";
import "src/misc/interfaces/IERC7575.sol";
import {SafeTransferLib} from "src/misc/libraries/SafeTransferLib.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {BaseVault, AsyncRedeemVault, BaseSyncDepositVault} from "src/vaults/BaseVaults.sol";
import {ISyncRequests} from "src/vaults/interfaces/investments/ISyncRequests.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";

/// @title  SyncDepositVault
/// @notice Partially (a)synchronous Tokenized Vault implementation with synchronous deposits and asynchronous
/// redemptions following ERC-7540.
///
/// @dev    Each vault issues shares of Centrifuge share class tokens as restricted ERC-20 or ERC-6909 tokens
///         against asset deposits based on the current share price.
contract SyncDepositVault is BaseSyncDepositVault, AsyncRedeemVault {
    constructor(
        PoolId poolId_,
        ShareClassId scId_,
        address asset_,
        uint256 tokenId_,
        IShareToken token_,
        address root_,
        ISyncDepositManager syncDepositManager_,
        IAsyncRedeemManager asyncRedeemManager_,
        IPoolEscrowProvider poolEscrowProvider_
    )
        BaseVault(poolId_, scId_, asset_, tokenId_, token_, root_, syncDepositManager_, poolEscrowProvider_)
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
