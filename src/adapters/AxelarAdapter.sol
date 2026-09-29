// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IAxelarAdapter,
    IAdapter,
    IAxelarGateway,
    IAxelarGasService,
    AxelarSource,
    AxelarDestination,
    IAxelarExecutable
} from "./interfaces/IAxelarAdapter.sol";

import {Auth} from "../misc/Auth.sol";
import {CastLib} from "../misc/libraries/CastLib.sol";

import {IAdapterEntrypoint} from "../core/messaging/interfaces/IAdapterEntrypoint.sol";

import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";
import {IAdapterGasService} from "../admin/interfaces/IAdapterGasService.sol";

/// @title  Axelar Adapter
/// @notice Routing contract that integrates with an Axelar Gateway
/// @dev    Replay protection is enforced by the Axelar Gateway via `validateContractCall()`,
///         which marks each command ID as consumed and reverts on reuse.
contract AxelarAdapter is Auth, IAxelarAdapter {
    using CastLib for *;

    IAdapterEntrypoint public immutable entrypoint;
    IAxelarGateway public immutable axelarGateway;
    IAxelarGasService public immutable axelarGasService;

    mapping(string axelarId => AxelarSource) public sources;
    mapping(uint16 centrifugeId => AxelarDestination) public destinations;

    constructor(IAdapterEntrypoint entrypoint_, address axelarGateway_, address axelarGasService_, address deployer)
        Auth(deployer)
    {
        entrypoint = entrypoint_;
        axelarGateway = IAxelarGateway(axelarGateway_);
        axelarGasService = IAxelarGasService(axelarGasService_);
    }

    //----------------------------------------------------------------------------------------------
    // Network wiring
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterWiring
    function wire(uint16 centrifugeId, bytes memory data) external auth {
        (string memory axelarId, string memory adapter) = abi.decode(data, (string, string));
        // keccak256("") is not empty, so a cleared source would still match a sender with no address
        sources[axelarId] =
            AxelarSource(centrifugeId, bytes(adapter).length == 0 ? bytes32(0) : keccak256(bytes(adapter)));
        destinations[centrifugeId] = AxelarDestination(axelarId, adapter);
        emit Wire(centrifugeId, axelarId, adapter);
    }

    /// @inheritdoc IAdapterWiring
    function isWired(uint16 centrifugeId, bytes memory data) external view returns (bool) {
        (string memory axelarId,) = abi.decode(data, (string, string));
        return bytes(destinations[centrifugeId].axelarId).length != 0 || sources[axelarId].addressHash != bytes32(0);
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAxelarExecutable
    function execute(
        bytes32 commandId,
        string calldata sourceAxelarId,
        string calldata sourceAddress,
        bytes calldata payload
    ) public {
        AxelarSource memory source = sources[sourceAxelarId];
        require(
            source.addressHash != bytes32("") && source.addressHash == keccak256(bytes(sourceAddress)), InvalidAddress()
        );

        require(
            axelarGateway.validateContractCall(commandId, sourceAxelarId, sourceAddress, keccak256(payload)),
            NotApprovedByGateway()
        );

        entrypoint.handle(source.centrifugeId, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(
        uint16 centrifugeId,
        bytes calldata payload,
        uint256,
        /* gasLimit */
        address refund
    )
        external
        payable
        returns (bytes32 adapterData)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        AxelarDestination memory destination = destinations[centrifugeId];
        require(bytes(destination.axelarId).length != 0, UnknownChainId());

        axelarGasService.payNativeGasForContractCall{value: msg.value}(
            address(this), destination.axelarId, destination.addr, payload, refund
        );

        axelarGateway.callContract(destination.axelarId, destination.addr, payload);

        adapterData = bytes32("");
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) external view returns (uint256) {
        AxelarDestination memory destination = destinations[centrifugeId];
        require(bytes(destination.axelarId).length != 0, UnknownChainId());

        return axelarGasService.estimateGasFee(
            destination.axelarId, destination.addr, payload, gasLimit + _receiveCost(centrifugeId), bytes("")
        );
    }

    /// @dev Receive reserve added to the requested gas limit. The gas service holds what this path costs
    ///      and what each destination charges for it, so the adapter only names itself.
    function _receiveCost(uint16 centrifugeId) internal view returns (uint256) {
        IAdapterGasService gasService = IAdapterGasService(address(entrypoint.messageGas()));
        return gasService.receiveCost(centrifugeId, "axelar");
    }
}
