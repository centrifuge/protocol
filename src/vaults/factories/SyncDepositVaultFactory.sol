// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {SyncDepositVault} from "src/vaults/SyncDepositVault.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";
import {IAsyncRedeemManager} from "src/vaults/interfaces/investments/IAsyncRedeemManager.sol";
import {ISyncDepositManager} from "src/vaults/interfaces/investments/ISyncDepositManager.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

/// @title  Sync Vault Factory
/// @dev    Utility for deploying new vault contracts
contract SyncDepositVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    ISyncDepositManager public immutable syncDepositManager;
    IAsyncRedeemManager public immutable asyncRedeemManager;

    constructor(
        address root_,
        ISyncDepositManager syncDepositManager_,
        IAsyncRedeemManager asyncRedeemManager_,
        address deployer
    ) Auth(deployer) {
        root = root_;
        syncDepositManager = syncDepositManager_;
        asyncRedeemManager = asyncRedeemManager_;
    }

    /// @inheritdoc IVaultFactory
    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        IShareToken token,
        address[] calldata wards_
    ) public auth returns (IBaseVault) {
        require(tokenId == 0, UnsupportedTokenId());
        SyncDepositVault vault =
            new SyncDepositVault(poolId, scId, asset, token, root, syncDepositManager, asyncRedeemManager);

        vault.rely(root);
        vault.rely(address(syncDepositManager));
        vault.rely(address(asyncRedeemManager));

        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        vault.deny(address(this));
        return vault;
    }
}
