// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {AsyncVault} from "src/vaults/AsyncVault.sol";
import {IVaultFactory} from "src/vaults/interfaces/factories/IVaultFactory.sol";
import {IPoolEscrowProvider} from "src/vaults/interfaces/factories/IPoolEscrowFactory.sol";
import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IAsyncRequests} from "src/vaults/interfaces/investments/IAsyncRequests.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

/// @title  ERC7540 Vault Factory
/// @dev    Utility for deploying new vault contracts
contract AsyncVaultFactory is Auth, IVaultFactory {
    address public immutable root;
    IAsyncRequests public immutable asyncRequests;
    IPoolEscrowProvider public immutable poolEscrowProvider;

    constructor(address root_, IAsyncRequests asyncRequests_, IPoolEscrowProvider poolEscrowProvider_, address deployer)
        Auth(deployer)
    {
        root = root_;
        asyncRequests = asyncRequests_;
        poolEscrowProvider = poolEscrowProvider_;
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
        AsyncVault vault = new AsyncVault(poolId, scId, asset, tokenId, token, root, asyncRequests, poolEscrowProvider);

        vault.rely(root);
        vault.rely(address(asyncRequests));
        uint256 wardsCount = wards_.length;
        for (uint256 i; i < wardsCount; i++) {
            vault.rely(wards_[i]);
        }

        vault.deny(address(this));
        return vault;
    }
}
