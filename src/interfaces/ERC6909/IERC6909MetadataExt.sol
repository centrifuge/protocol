// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

interface IERC6909MetadataExt {
    /// @notice             Used to retrieve the decimals of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function decimals(uint256 assetId) external view returns (uint8);

    /// @notice             Used to retrieve the name of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function name(uint256 assetId) external view returns (string memory);

    /// @notice             Used to retrieve the symbol of an asset
    /// @dev                address is used but the value corresponds to a AssetId
    function symbol(uint256 assetId) external view returns (string memory);
}
