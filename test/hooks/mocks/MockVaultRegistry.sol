// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {PoolId} from "../../../src/core/types/PoolId.sol";
import {ShareClassId} from "../../../src/core/types/ShareClassId.sol";
import {VaultDetails} from "../../../src/core/spoke/interfaces/ISpokeRegistry.sol";

/// @dev The two spoke registry reads a transfer hook makes to recognise a vault of a token's own share
///      class: the vault's registered (pool, share class) and whether it is linked, and the share token
///      that pair issues. Everything unset reads as unregistered.
contract MockVaultRegistry {
    mapping(address => VaultDetails) internal _vaultDetails;
    mapping(PoolId => mapping(ShareClassId => address)) public shareToken;

    function setShareToken(PoolId poolId, ShareClassId scId, address token) external {
        shareToken[poolId][scId] = token;
    }

    function setVault(address vault, PoolId poolId, ShareClassId scId, bool isLinked) external {
        _vaultDetails[vault].poolId = poolId;
        _vaultDetails[vault].scId = scId;
        _vaultDetails[vault].asset = address(1);
        _vaultDetails[vault].isLinked = isLinked;
    }

    function vaultDetails(address vault) external view returns (VaultDetails memory) {
        return _vaultDetails[vault];
    }
}
