// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

/// @notice A stripped down version of the Centrifuge V2 ERC-7540 vault.
///
/// @dev This interface is needed to ensure adapters for legacy vaults are provided with the expected interface.
interface IVault {
    /// @notice Documentation see Centrifuge V2 repository.
    function poolId() external view returns (uint64);

    /// @notice Documentation see Centrifuge V2 repository.
    function trancheId() external view returns (bytes16);

    /// @notice Documentation see Centrifuge V2 repository.
    function asset() external view returns (address);

    /// @notice Documentation see Centrifuge V2 repository.
    function share() external view returns (address);
}
