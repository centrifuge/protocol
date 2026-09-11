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

import {IMessageHandler} from "../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";

/// @title  Axelar Adapter
/// @notice Routing contract that integrates with an Axelar Gateway
/// @dev    Replay protection is enforced by the Axelar Gateway via `validateContractCall()`,
///         which marks each command ID as consumed and reverts on reuse.
contract AxelarAdapter is Auth, IAxelarAdapter {
    using CastLib for *;

    /// @dev Cost of executing `execute()` except entrypoint.handle(), reserved per destination chain.
    /// NOTE: Tested in production using real `validateContractCall()` implementation.
    uint256 public constant DEFAULT_RECEIVE_COST = 26000;

    uint16 public constant MONAD_CENTRIFUGE_ID = 11;
    // Monad reprices cold storage access (2100→8100, +6000/slot) and cold account access (2600→10100,
    // +7500/call) per its published opcode schedule (docs.monad.xyz). execute() makes 2 cold SLOADs (a
    // uint16 + a bytes32 spanning two slots) + 2 cold CALLs (validateContractCall, entrypoint) =>
    // +27_000 over DEFAULT. The gateway's own internal cold writes aren't separately reserved, so this
    // figure may be low. Mirrors GasService.
    uint256 public constant MONAD_RECEIVE_COST = DEFAULT_RECEIVE_COST + 27_000;

    IMessageHandler public immutable entrypoint;
    IAxelarGateway public immutable axelarGateway;
    IAxelarGasService public immutable axelarGasService;

    mapping(string axelarId => AxelarSource) public sources;
    mapping(uint16 centrifugeId => AxelarDestination) public destinations;

    constructor(IMessageHandler entrypoint_, address axelarGateway_, address axelarGasService_, address deployer)
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
        sources[axelarId] = AxelarSource(centrifugeId, keccak256(bytes(adapter)));
        destinations[centrifugeId] = AxelarDestination(axelarId, adapter);
        emit Wire(centrifugeId, axelarId, adapter);
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

    /// @dev Per-destination receive reserve added to the requested gas limit; Monad's cold-access
    ///      repricing needs a larger reserve than other chains.
    function _receiveCost(uint16 centrifugeId) internal pure returns (uint256) {
        return centrifugeId == MONAD_CENTRIFUGE_ID ? MONAD_RECEIVE_COST : DEFAULT_RECEIVE_COST;
    }
}
