// SPDX-License-Identifier: BUSL-1.1
pragma solidity >=0.5.0;

interface ILegacyVaultAdapter {
    error NotLegacyVault(address sender, address legacyVault);
    error NotLegacyPoolId(uint64 providedPoolId, uint64 legacyPoolId);
    error NotLegacyTrancheId(bytes16 providedTrancheId, bytes16 legacyTrancheId);
    error NotLegacyAsset(address providedAsset, address legacyAsset);
    error NotLegacyShare(address providedShare, address legacyShare);
}
