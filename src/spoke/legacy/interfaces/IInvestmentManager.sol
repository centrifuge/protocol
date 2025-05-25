// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity >=0.5.0;

/// @notice A stripped down version of the Centrifuge V2 investment manager.
///
/// @dev This interface is needed to ensure adapters for legacy vaults are provided with the expected interface.
interface IInvestmentManager {
    /// @notice Documentation see Centrifuge V2 repository.
    function escrow() external view returns (address);

    // --- Outgoing message handling ---
    /// @notice Documentation see Centrifuge V2 repository.
    function requestDeposit(address vault, uint256 assets, address receiver, address owner, address source)
        external
        returns (bool);

    /// @notice Documentation see Centrifuge V2 repository.
    function requestRedeem(address vault, uint256 shares, address receiver, address, /* owner */ address source)
        external
        returns (bool);

    /// @notice Documentation see Centrifuge V2 repository.
    function cancelDepositRequest(address vault, address owner, address source) external;

    /// @notice Documentation see Centrifuge V2 repository.
    function cancelRedeemRequest(address vault, address owner, address source) external;

    // --- View functions ---
    /// @notice Documentation see Centrifuge V2 repository.
    function convertToShares(address vault, uint256 _assets) external view returns (uint256 shares);

    /// @notice Documentation see Centrifuge V2 repository.
    function convertToAssets(address vault, uint256 _shares) external view returns (uint256 assets);

    /// @notice Documentation see Centrifuge V2 repository.
    function maxDeposit(address vault, address user) external view returns (uint256);

    /// @notice Documentation see Centrifuge V2 repository.
    function maxMint(address vault, address user) external view returns (uint256 shares);

    /// @notice Documentation see Centrifuge V2 repository.
    function maxWithdraw(address vault, address user) external view returns (uint256 assets);

    /// @notice Documentation see Centrifuge V2 repository.
    function maxRedeem(address vault, address user) external view returns (uint256 shares);

    /// @notice Documentation see Centrifuge V2 repository.
    function pendingDepositRequest(address vault, address user) external view returns (uint256 assets);

    /// @notice Documentation see Centrifuge V2 repository.
    function pendingRedeemRequest(address vault, address user) external view returns (uint256 shares);

    /// @notice Documentation see Centrifuge V2 repository.
    function pendingCancelDepositRequest(address vault, address user) external view returns (bool isPending);

    /// @notice Documentation see Centrifuge V2 repository.
    function pendingCancelRedeemRequest(address vault, address user) external view returns (bool isPending);

    /// @notice Documentation see Centrifuge V2 repository.
    function claimableCancelDepositRequest(address vault, address user) external view returns (uint256 assets);

    /// @notice Documentation see Centrifuge V2 repository.
    function claimableCancelRedeemRequest(address vault, address user) external view returns (uint256 shares);

    /// @notice Documentation see Centrifuge V2 repository.
    function priceLastUpdated(address vault) external view returns (uint64 lastUpdated);

    // --- Vault claim functions ---
    /// @notice Documentation see Centrifuge V2 repository.
    function deposit(address vault, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Documentation see Centrifuge V2 repository.
    function mint(address vault, uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Documentation see Centrifuge V2 repository.
    function redeem(address vault, uint256 shares, address receiver, address owner) external returns (uint256 assets);

    /// @notice Documentation see Centrifuge V2 repository.
    function withdraw(address vault, uint256 assets, address receiver, address owner)
        external
        returns (uint256 shares);

    /// @notice Documentation see Centrifuge V2 repository.
    function claimCancelDepositRequest(address vault, address receiver, address owner)
        external
        returns (uint256 assets);

    /// @notice Documentation see Centrifuge V2 repository.
    function claimCancelRedeemRequest(address vault, address receiver, address owner)
        external
        returns (uint256 shares);
}
