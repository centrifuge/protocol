// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IERC6909MetadataExt {
    /// @notice             Used to retrieve the decimals of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function decimals(address assetId) external view returns (uint8);

    /// @notice             Used to retrieve the name of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function name(address assetId) external view returns (bytes memory);

    /// @notice             Used to retrieve the symbol of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function symbol(address assetId) external view returns (bytes32);
}
