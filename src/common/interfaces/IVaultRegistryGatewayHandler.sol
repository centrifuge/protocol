// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../types/PoolId.sol";
import {AssetId} from "../types/AssetId.sol";
import {ShareClassId} from "../types/ShareClassId.sol";
import {VaultUpdateKind} from "../libraries/MessageLib.sol";

/// @notice Interface for VaultRegistry methods called by messages
interface IVaultRegistryGatewayHandler {
    /// @notice Updates a vault based on VaultUpdateKind
    /// @param  poolId The centrifuge pool id
    /// @param  scId The share class id
    /// @param  assetId The asset id
    /// @param  vaultOrFactory The address of the vault or the factory, depending on the kind value
    /// @param  kind The kind of action applied
    function updateVault(
        PoolId poolId,
        ShareClassId scId,
        AssetId assetId,
        address vaultOrFactory,
        VaultUpdateKind kind
    ) external;
}
