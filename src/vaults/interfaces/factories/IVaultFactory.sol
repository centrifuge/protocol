// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "src/common/types/PoolId.sol";
import {ShareClassId} from "src/common/types/ShareClassId.sol";

import {IShareToken} from "src/vaults/interfaces/token/IShareToken.sol";
import {IPoolEscrow} from "src/vaults/interfaces/IEscrow.sol";
import {IBaseVault} from "src/vaults/interfaces/IBaseVaults.sol";

interface IVaultFactory {
    error UnsupportedTokenId();

    /// @notice Deploys new vault for `poolId`, `scId` and `asset`.
    ///
    /// @param poolId Id of the pool. Id is one of the already supported pools.
    /// @param scId Id of the share class token. Id is one of the already supported share class tokens.
    /// @param asset Address of the underlying asset that is getting deposited inside the pool.
    /// @param asset Token id of the underlying asset that is getting deposited inside the pool. I.e. zero if asset
    /// corresponds to ERC20 or non-zero if asset corresponds to ERC6909.
    /// @param token Address of the share class token that is getting issues against the deposited asset.
    /// @param wards_ Address which can call methods behind authorized only.
    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        IShareToken token,
        address[] calldata wards_
    ) external returns (IBaseVault);
}
