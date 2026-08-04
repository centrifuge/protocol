// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../../src/core/types/PoolId.sol";
import {AssetId} from "../../../../src/core/types/AssetId.sol";
import {ShareClassId} from "../../../../src/core/types/ShareClassId.sol";

/// @notice Selectors that existed on the v3.1 VaultRegistry but have no equivalent on the current
///         {ISpokeRegistry}, which resolves vaults via the ERC-7575 pointer instead. Everything else the
///         fork tests read off a live v3.1 deployment still matches {ISpokeRegistry} selector-for-selector,
///         so it is called through that interface directly.
interface IV3_1_VaultRegistry {
    /// @dev `manager` is an address here rather than ISpokeRequestManager; contract types encode as `address`,
    ///      so the selector is unchanged.
    function vault(PoolId poolId, ShareClassId scId, AssetId assetId, address manager) external view returns (address);
}
