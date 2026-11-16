// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../types/PoolId.sol";
import {ShareClassId} from "../../../types/ShareClassId.sol";

/// @title  IVaultFactory
/// @notice Factory for deploying vault contracts for pool share classes
/// @dev    Creates vaults linking pool IDs, share class IDs, assets, and tokens.
///
///         Factory convention: a factory MUST expose a deterministic pre-deployment address view
///         ({getVault}), so addresses (used as primary keys, and cross-chain) are knowable before
///         deployment. The deployment event is emitted by the registry ({ISpokeRegistry.DeployVault}),
///         the sole caller of {newVault}, so a separate factory-level event is not needed.
///
///         Vault convention: the vault a factory returns MUST implement {IVaultPosition} and name the pool and
///         share class it was built for. The spoke handler refuses a vault that names another position when
///         `DeployAndLink` registers it, which is what keeps a pool from registering a vault built for a different
///         one: the factory is whatever address the pool's message names, so what it says about its own vault proves
///         nothing.
interface IVaultFactory {
    error UnsupportedTokenId();

    /// @notice The deterministic address of the vault {newVault} returns for these parameters.
    /// @dev    Computed from the factory's CREATE2 salt and init code, so it is valid before deployment.
    ///         Takes `payload` because a factory may derive the vault's address from it.
    function getVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address token,
        bytes calldata payload
    ) external view returns (address vault);

    /// @notice Returns the vault for `poolId`, `scId` and `asset`, at {getVault}'s address. A factory may deploy it
    ///         here, or return one deployed ahead of the call.
    ///
    /// @param poolId Id of the pool. Id is one of the already supported pools.
    /// @param scId Id of the share class token. Id is one of the already supported share class tokens.
    /// @param asset Address of the underlying asset that is getting deposited inside the pool.
    /// @param tokenId Token id of the underlying asset that is getting deposited inside the pool.
    ///              I.e. zero if asset corresponds to ERC20 or non-zero if asset corresponds to ERC6909.
    /// @param token Address of the share class token that is getting issues against the deposited asset.
    /// @param payload Opaque, factory-defined deployment data forwarded from the hub. The core does not
    ///               inspect or validate it in any way; interpreting it is entirely the factory's
    ///               responsibility. Empty for factories that need no extra configuration; such factories
    ///               must ignore it.
    function newVault(
        PoolId poolId,
        ShareClassId scId,
        address asset,
        uint256 tokenId,
        address token,
        bytes calldata payload
    ) external returns (address);
}
