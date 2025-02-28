// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {IMessageHandler} from "src/vaults/interfaces/gateway/IGateway.sol";
import {IRecoverable} from "src/vaults/interfaces/IRoot.sol";

interface IInstantManager is IMessageHandler, IRecoverable {
    // --- Events ---
    event File(bytes32 indexed what, address data);

    error PriceTooOld();

    /// @notice Updates contract parameters of type address.
    /// @param what The bytes32 representation of 'gateway' or 'poolManager'.
    /// @param data The new contract address.
    function file(bytes32 what, address data) external;

    function escrow() external view returns (address);
    function maxDeposit(address vault, address owner) external view returns (uint256);
    function previewDeposit(address vault, address sender, uint256 assets) external view returns (uint256);
    function deposit(address vault, uint256 assets, address receiver, address owner) external returns (uint256);
    function maxMint(address vault, address owner) external view returns (uint256);
    function previewMint(address vault, address sender, uint256 shares) external view returns (uint256);
    function mint(address vault, uint256 shares, address receiver, address owner) external returns (uint256);

    /// @notice Handle incoming messages from Centrifuge. Parse the function params and forward to the corresponding
    ///         handler function.
    function handle(bytes calldata message) external;
}
