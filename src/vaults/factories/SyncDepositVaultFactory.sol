// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "../../misc/Auth.sol";
import {IAuth} from "../../misc/interfaces/IAuth.sol";

import {PoolId} from "../../common/types/PoolId.sol";
import {ShareClassId} from "../../common/types/ShareClassId.sol";

import {IVault} from "../../spoke/interfaces/IVault.sol";
import {IShareToken} from "../../spoke/interfaces/IShareToken.sol";
import {IVaultFactory} from "../../spoke/factories/interfaces/IVaultFactory.sol";

import {SyncDepositVault} from "../SyncDepositVault.sol";
import {IAsyncRedeemManager} from "../interfaces/IVaultManagers.sol";
import {ISyncDepositManager} from "../interfaces/IVaultManagers.sol";

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
    ) public auth returns (IVault) {
        require(tokenId == 0, UnsupportedTokenId());
        SyncDepositVault vault =
            new SyncDepositVault(poolId, scId, asset, token, root, syncDepositManager, asyncRedeemManager);

        vault.rely(root);
        vault.rely(address(syncDepositManager));
        vault.rely(address(asyncRedeemManager));

        IAuth(address(syncDepositManager)).rely(address(vault));
        IAuth(address(asyncRedeemManager)).rely(address(vault));

        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        vault.deny(address(this));
        return vault;
    }
}
