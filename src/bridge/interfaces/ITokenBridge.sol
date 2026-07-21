// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";
import {ITrustedContractUpdate} from "../../core/utils/interfaces/IContractUpdate.sol";

interface ITokenBridge is IRecoverable, ITrustedContractUpdate {
    event File(bytes32 indexed what, address data);
    event File(bytes32 indexed what, uint256 evmChainId, uint16 centrifugeId);
    event UpdateGasLimits(
        PoolId indexed poolId, ShareClassId indexed scId, uint128 extraGasLimit, uint128 remoteExtraGasLimit
    );
    event Send(
        address indexed token,
        address indexed sender,
        uint256 destinationChainId,
        bytes32 receiver,
        uint256 amount,
        address refundAddress
    );

    error NotBatchable();
    error FileUnrecognizedParam();
    error InvalidChainId();
    error UnknownTrustedCall();
    error ShareTokenDoesNotExist();

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
    /// @dev    For spoke -> hub -> spoke transfers the contract routes the first-leg refund to the configured
    ///         relayer so it can pay for the second leg on the hub. If no relayer is set, the first-leg
    ///         overpayment is returned to refundAddress and the second leg is queued as underpaid by the
    ///         Gateway — a manual Gateway.repay call is then required to complete the transfer.
    /// @param token The address of the token sending across chains
    /// @param amount The amount of the token to send across chains
    /// @param receiver The target address that should receive the funds on the destination chain
    /// @param destinationChainId The Ethereum chain ID of the destination chain
    /// @param refundAddress The address that should receive any excess gas funds, given that they are not sent
    ///                      to the relayer
    /// @return The response from the token's handler function (not standardized)
    function send(address token, uint256 amount, bytes32 receiver, uint256 destinationChainId, address refundAddress)
        external
        payable
        returns (bytes memory);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the Centrifuge chain ID of the chain this contract is deployed on
    function localCentrifugeId() external view returns (uint16);

    /// @notice Returns the relayer address
    function relayer() external view returns (address);

    /// @notice Returns the gateway this contract routes transfers through
    function gateway() external view returns (IGateway);

    /// @notice Returns the Centrifuge chain ID for a given EVM chain ID
    function chainIdToCentrifugeId(uint256 evmChainId) external view returns (uint16);
}
