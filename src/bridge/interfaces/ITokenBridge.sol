// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

interface ITokenBridge is ITrustedContractUpdate {
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 evmChainId, uint16 centrifugeId);
    event UpdateGasLimits(
        PoolId indexed poolId, ShareClassId indexed scId, uint128 extraGasLimit, uint128 remoteExtraGasLimit
    );

    error FileUnrecognizedParam();
    error InvalidChainId();
    error InvalidRelayer();
    error InvalidToken();
    error UnknownTrustedCall();
    error ShareTokenDoesNotExist();
    error FailedToTransferToRelayer();

    enum TrustedCall {
        SetGasLimits
    }

    struct GasLimits {
        uint128 extraGasLimit;
        uint128 remoteExtraGasLimit;
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @notice Configure contract parameters
    /// @param what The parameter name to configure
    /// @param data The address value to set
    function file(bytes32 what, address data) external;

    /// @notice Configure chain ID mapping
    /// @param what Must be "centrifugeId"
    /// @param evmChainId The EVM chain ID
    /// @param centrifugeId The corresponding Centrifuge chain ID
    function file(bytes32 what, uint256 evmChainId, uint16 centrifugeId) external;

    //----------------------------------------------------------------------------------------------
    // Bridging
    //----------------------------------------------------------------------------------------------

    /// @notice Send a token from chain A to chain B after approving this contract with the token
    /// @dev This function transfers tokens from the caller and initiates a cross-chain transfer
    /// @dev These methods match the expected interface from Glacis Airlift for cross-chain token transfers
    /// @param token The address of the token sending across chains
    /// @param amount The amount of the token to send across chains
    /// @param receiver The target address that should receive the funds on the destination chain
    /// @param destinationChainId The Ethereum chain ID of the destination chain
    /// @param refundAddress The address that should receive any funds if the cross-chain gas value is too high
    /// @return sendResponse The response from the token's handler function (not standardized)
    function send(address token, uint256 amount, bytes32 receiver, uint256 destinationChainId, address refundAddress)
        external
        payable
        returns (bytes memory);

    /// @notice Send a token from chain A to chain B with a specific output token
    /// @dev This allows routing through a specific bridge when multiple bridges are available
    /// @dev These methods match the expected interface from Glacis Airlift for cross-chain token transfers
    /// @param token The address of the token sending across chains
    /// @param amount The amount of the token to send across chains
    /// @param receiver The target address that should receive the funds on the destination chain
    /// @param destinationChainId The Ethereum chain ID of the destination chain
    /// @param refundAddress The address that should receive any funds if the cross-chain gas value is too high
    /// @param outputToken The address of the token to receive on the destination chain
    /// @return sendResponse The response from the token's handler function (not standardized)
    function send(
        address token,
        uint256 amount,
        bytes32 receiver,
        uint256 destinationChainId,
        address refundAddress,
        bytes32 outputToken
    ) external payable returns (bytes memory);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the relayer address
    /// @return The relayer address
    function relayer() external view returns (address);
}
