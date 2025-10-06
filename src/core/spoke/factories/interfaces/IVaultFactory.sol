// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../types/PoolId.sol";
import {IVault} from "../../interfaces/IVault.sol";
import {IShareToken} from "../../interfaces/IShareToken.sol";
import {ShareClassId} from "../../../types/ShareClassId.sol";

/// @title  IVaultFactory
/// @notice Factory for deploying vault contracts for pool share classes
/// @dev    Creates vaults linking pool IDs, share class IDs, assets, and tokens
interface IVaultFactory {
    error UnsupportedTokenId();

    /// @notice Deploys new vault for `poolId`, `scId` and `asset`.
    ///
    /// @param poolId Id of the pool. Id is one of the already supported pools.
    /// @param scId Id of the share class token. Id is one of the already supported share class tokens.
    /// @param asset Address of the underlying asset that is getting deposited inside the pool.
    /// @param asset Token id of the underlying asset that is getting deposited inside the pool.
    ///              I.e. zero if asset corresponds to ERC20 or non-zero if asset corresponds to ERC6909.
    /// @param token Address of the share class token that is getting issues against the deposited asset.
    /// @param wards_ Address which can call methods behind authorized only.
    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        IShareToken token,
        address[] calldata wards_
    ) external returns (IVault);
}
