// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

import {IRecoverable} from "../../misc/interfaces/IRecoverable.sol";

import {PoolId} from "../../core/types/PoolId.sol";
import {ShareClassId} from "../../core/types/ShareClassId.sol";
import {IGateway} from "../../core/messaging/interfaces/IGateway.sol";

interface ITokenBridge is IRecoverable {
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

    error NotEnvoy();
    error UnexpectedValue();
    error NotBatchable();
    error FileUnrecognizedParam();
    error InvalidChainId();
    error ShareTokenDoesNotExist();

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
    /// @param token The address of the token sending across chains
    /// @param amount The amount of the token to send across chains
    /// @param receiver The target address that should receive the funds on the destination chain
    /// @param destinationChainId The Ethereum chain ID of the destination chain
    /// @param refundAddress The address that should receive any funds if the cross-chain gas value is too high
    /// @return Always returns empty bytes
    function send(address token, uint256 amount, bytes32 receiver, uint256 destinationChainId, address refundAddress)
        external
        payable
        returns (bytes memory);

    //----------------------------------------------------------------------------------------------
    // View methods
    //----------------------------------------------------------------------------------------------

    /// @notice Returns the Centrifuge chain ID of the chain this contract is deployed on
    function localCentrifugeId() external view returns (uint16);

    /// @notice Returns the envoy that routes hub-dispatched configuration updates
    function envoy() external view returns (address);

    /// @notice Returns the relayer address
    function relayer() external view returns (address);

    /// @notice Returns the gateway this contract routes transfers through
    function gateway() external view returns (IGateway);

    /// @notice Returns the Centrifuge chain ID for a given EVM chain ID
    function chainIdToCentrifugeId(uint256 evmChainId) external view returns (uint16);
}
