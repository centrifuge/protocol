// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../../core/types/PoolId.sol";
import {AssetId} from "../../../core/types/AssetId.sol";
import {ISpoke} from "../../../core/spoke/interfaces/ISpoke.sol";
import {ShareClassId} from "../../../core/types/ShareClassId.sol";
import {ISpokeRegistry} from "../../../core/spoke/interfaces/ISpokeRegistry.sol";
import {IVaultFactory} from "../../../core/spoke/factories/interfaces/IVaultFactory.sol";

import {VaultPlugins} from "../../interfaces/IAsyncVault.sol";

/// @notice A vault factory whose vaults anyone deploys ahead of the hub's `DeployAndLink`, which then only finds them.
interface IVaultDeployFactory is IVaultFactory {
    /// @notice What a hub `DeployAndLink` carries for this factory, ABI-encoded as the payload.
    /// @param  variant Lets parallel vaults coexist on one position
    /// @param  foldHorizon The vault's `foldHorizon`, zero for its default
    struct Payload {
        VaultPlugins plugins;
        uint64 variant;
        uint256 foldHorizon;
    }

    /// @notice A vault was deployed, with the whole of its identity and configuration: nothing needs the registry's
    ///         `DeployVault` payload decoded or a call to the vault. `config` is the payload as sent, so re-encoding it
    ///         gives the vault's address, and `foldHorizon` the horizon the vault resolved from it. Not emitted when
    ///         the vault already existed.
    event VaultDeployed(
        PoolId indexed poolId,
        ShareClassId indexed scId,
        address indexed asset,
        AssetId assetId,
        address vault,
        address share,
        address escrow,
        ISpoke spoke,
        ISpokeRegistry spokeRegistry,
        Payload config,
        uint256 foldHorizon
    );

    /// @notice The payload is empty, so it names no plugins.
    error PluginsRequired();

    /// @notice The vault could not be created and gave no reason.
    error DeploymentFailed();

    /// @notice No vault is deployed yet at the address the hub asked to link.
    error VaultNotDeployed();

    /// @notice Deploys the vault that a hub `DeployAndLink` with the same arguments links. Permissionless.
    /// @dev    The payload is `abi.encode(Payload)`, with no default plugins; a zero `foldHorizon` takes the vault's
    ///         default. The share class must already be on the spoke, since the vault reads its token and the pool's
    ///         escrow.
    /// @return The vault deployed, or the one already there when someone deployed it first
    function deploy(PoolId poolId, ShareClassId scId, address asset, uint256 tokenId, bytes calldata payload)
        external
        returns (address);
}
