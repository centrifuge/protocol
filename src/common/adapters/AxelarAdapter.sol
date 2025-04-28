// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {Auth} from "src/misc/Auth.sol";
import {CastLib} from "src/misc/libraries/CastLib.sol";
import {
    IAxelarAdapter,
    IAdapter,
    IAxelarGateway,
    IAxelarGasService,
    AxelarSource,
    AxelarDestination,
    IAxelarExecutable
} from "src/common/interfaces/IAxelarAdapter.sol";
import {IMessageHandler} from "src/common/interfaces/IMessageHandler.sol";

/// @title  Axelar Adapter
/// @notice Routing contract that integrates with an Axelar Gateway
contract AxelarAdapter is Auth, IAxelarAdapter {
    using CastLib for *;

    IMessageHandler public immutable gateway;
    IAxelarGateway public immutable axelarGateway;
    IAxelarGasService public immutable axelarGasService;

    mapping(string axelarId => AxelarSource) public sources;
    mapping(uint16 centrifugeId => AxelarDestination) public destinations;

    constructor(IMessageHandler gateway_, address axelarGateway_, address axelarGasService_, address deployer)
        Auth(deployer)
    {
        gateway = gateway_;
        axelarGateway = IAxelarGateway(axelarGateway_);
        axelarGasService = IAxelarGasService(axelarGasService_);
    }

    //----------------------------------------------------------------------------------------------
    // Administration
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAxelarAdapter
    function file(bytes32 what, string calldata axelarId, uint16 centrifugeId, address source) external auth {
        if (what == "sources") sources[axelarId] = AxelarSource(centrifugeId, source);
        else revert FileUnrecognizedParam();
        emit File(what, axelarId, centrifugeId, source);
    }

    /// @inheritdoc IAxelarAdapter
    function file(bytes32 what, uint16 centrifugeId, string calldata axelarId, address destination) external auth {
        if (what == "destinations") destinations[centrifugeId] = AxelarDestination(axelarId, destination);
        else revert FileUnrecognizedParam();
        emit File(what, centrifugeId, axelarId, destination);
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
        require(source.addr != address(0) && source.addr == sourceAddress.toAddress(), InvalidAddress());

        require(
            axelarGateway.validateContractCall(commandId, sourceAxelarId, sourceAddress, keccak256(payload)),
            NotApprovedByGateway()
        );

        gateway.handle(source.centrifugeId, payload);
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256, /* gasLimit */ address refund)
        external
        payable
        returns (bytes32 adapterData)
    {
        require(msg.sender == address(gateway), NotGateway());
        AxelarDestination memory destination = destinations[centrifugeId];
        require(bytes(destination.axelarId).length != 0, UnknownChainId());

        string memory destinationAddress = destination.addr.toString();
        axelarGasService.payNativeGasForContractCall{value: msg.value}(
            address(this), destination.axelarId, destinationAddress, payload, refund
        );

        axelarGateway.callContract(destination.axelarId, destinationAddress, payload);

        adapterData = bytes32("");
    }

    /// @inheritdoc IAdapter
    function estimate(uint16 centrifugeId, bytes calldata payload, uint256 gasLimit) public view returns (uint256) {
        AxelarDestination memory destination = destinations[centrifugeId];
        return axelarGasService.estimateGasFee(
            destination.axelarId, destination.addr.toString(), payload, gasLimit, bytes("")
        );
    }
}
