// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IERC165} from "src/misc/interfaces/IERC7575.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {BaseVault} from "src/spoke/vaults/BaseVaults.sol";
import {BaseAsyncRedeemVault, BaseSyncDepositVault} from "src/spoke/vaults/BaseVaults.sol";
import {IShareToken} from "src/spoke/interfaces/IShareToken.sol";
import {IAsyncRedeemManager} from "src/spoke/vaults/interfaces/IVaultManagers.sol";
import {ISyncDepositManager} from "src/spoke/vaults/interfaces/IVaultManagers.sol";
import {IBaseRequestManager} from "src/spoke/vaults/interfaces/IBaseRequestManager.sol";
import {VaultKind} from "src/spoke/vaults/interfaces/IBaseVault.sol";

/// @title  SyncDepositVault
/// @notice Partially (a)synchronous Tokenized Vault implementation with synchronous deposits
///         and asynchronous redemptions following ERC-7540.
///
/// @dev    Each vault issues shares of Centrifuge share class tokens as restricted ERC-20 tokens
///         against asset deposits based on the current share price.
contract SyncDepositVault is BaseSyncDepositVault, BaseAsyncRedeemVault {
    constructor(
        PoolId poolId_,
        ShareClassId scId_,
        address asset_,
        IShareToken token_,
        address root_,
        ISyncDepositManager syncDepositManager_,
        IAsyncRedeemManager asyncRedeemManager_
    )
        BaseVault(poolId_, scId_, asset_, token_, root_, syncDepositManager_)
        BaseSyncDepositVault(syncDepositManager_)
        BaseAsyncRedeemVault(asyncRedeemManager_)
    {}

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    function file(bytes32 what, address data) external override(BaseAsyncRedeemVault, BaseVault) auth {
        if (what == "manager") manager = IBaseRequestManager(data);
        else if (what == "asyncRedeemManager") asyncRedeemManager = IAsyncRedeemManager(data);
        else if (what == "syncDepositManager") syncDepositManager = ISyncDepositManager(data);
        else revert FileUnrecognizedParam();
        emit File(what, data);
    }

    //----------------------------------------------------------------------------------------------
    // ERC-165
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        pure
        override(BaseAsyncRedeemVault, BaseSyncDepositVault)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    //----------------------------------------------------------------------------------------------
    // IBaseVault view
    //----------------------------------------------------------------------------------------------

    function vaultKind() public pure returns (VaultKind vaultKind_) {
        return VaultKind.SyncDepositAsyncRedeem;
    }
}
