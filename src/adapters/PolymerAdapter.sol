// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {
    IPolymerAdapter,
    IAdapter,
    ICrossL2ProverV2,
    PolymerSource,
    PolymerDestination
} from "./interfaces/IPolymerAdapter.sol";

import {Auth} from "../misc/Auth.sol";

import {IMessageHandler} from "../core/messaging/interfaces/IMessageHandler.sol";

import {IAdapterWiring} from "../admin/interfaces/IAdapterWiring.sol";

/// @title  Polymer Adapter
/// @notice Routing contract that integrates with Polymer's event-proving protocol.
/// @dev    Outbound: emits a `SendMessage` event on the source chain.
///         Inbound: anyone can submit a Polymer proof to `receiveMessage()`, which
///         validates it via the `ICrossL2ProverV2` prover contract.
///
///         Polymer has no onchain fee mechanism. Relaying proofs and paying for
///         destination gas must be handled by an off-chain relayer.
///
///         Replay protection is enforced by this adapter using per-source-chain nonces.
///         The Polymer prover validates proof authenticity but does not track consumption,
///         so nonce-based deduplication is required at the adapter level.
contract PolymerAdapter is Auth, IPolymerAdapter {
    /// @dev Event selector for `SendMessage(uint16,address,uint256,bytes)`.
    ///      Used to validate the proven event matches expectations.
    bytes32 public immutable SEND_MESSAGE_SELECTOR = SendMessage.selector;

    IMessageHandler public immutable entrypoint;
    ICrossL2ProverV2 public immutable prover;

    uint256 public currentNonce;
    mapping(uint16 centrifugeId => PolymerDestination) public destinations;
    mapping(uint32 polymerChainId => PolymerSource) public sources;
    mapping(uint32 polymerChainId => mapping(uint256 nonce => bool)) public processedNonces;

    constructor(IMessageHandler entrypoint_, address prover_, address deployer) Auth(deployer) {
        entrypoint = entrypoint_;
        prover = ICrossL2ProverV2(prover_);
    }

    //----------------------------------------------------------------------------------------------
    // Network wiring
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapterWiring
    function wire(uint16 centrifugeId, bytes memory data) external auth {
        (uint32 polymerChainId, address adapter) = abi.decode(data, (uint32, address));
        sources[polymerChainId] = PolymerSource(centrifugeId, adapter);
        destinations[centrifugeId] = PolymerDestination(polymerChainId, adapter);
        emit Wire(centrifugeId, polymerChainId, adapter);
    }

    /// @inheritdoc IAdapterWiring
    function isWired(uint16 centrifugeId) external view returns (bool) {
        return destinations[centrifugeId].polymerChainId != 0;
    }

    //----------------------------------------------------------------------------------------------
    // Incoming
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IPolymerAdapter
    function receiveMessage(bytes calldata proof) external {
        (uint32 chainId, address emittingContract, bytes memory topics, bytes memory unindexedData) =
            prover.validateEvent(proof);

        require(topics.length == 128, InvalidProof());
        (bytes32 eventSelector,, address destAdapter, uint256 sourceNonce) =
            abi.decode(topics, (bytes32, uint16, address, uint256));
        require(eventSelector == SEND_MESSAGE_SELECTOR && destAdapter == address(this), InvalidProof());

        PolymerSource memory source = sources[chainId];
        require(source.addr != address(0) && source.addr == emittingContract, InvalidSource());

        require(!processedNonces[chainId][sourceNonce], AlreadyProcessed());
        processedNonces[chainId][sourceNonce] = true;

        entrypoint.handle(source.centrifugeId, abi.decode(unindexedData, (bytes)));
    }

    //----------------------------------------------------------------------------------------------
    // Outgoing
    //----------------------------------------------------------------------------------------------

    /// @inheritdoc IAdapter
    function send(uint16 centrifugeId, bytes calldata payload, uint256, /* gasLimit */ address /* refund */ )
        external
        payable
        returns (bytes32 adapterData)
    {
        require(msg.sender == address(entrypoint), NotEntrypoint());
        PolymerDestination memory destination = destinations[centrifugeId];
        require(destination.polymerChainId != 0, UnknownChainId());

        uint256 nonce_ = currentNonce++;
        emit SendMessage(centrifugeId, destination.addr, nonce_, payload);
        adapterData = bytes32(nonce_);
    }

    /// @inheritdoc IAdapter
    /// @dev Polymer sending is event-based with no onchain fee. Returns 0.
    function estimate(uint16 centrifugeId, bytes calldata, /* payload */ uint256 /* gasLimit */ )
        external
        view
        returns (uint256)
    {
        PolymerDestination memory destination = destinations[centrifugeId];
        require(destination.polymerChainId != 0, UnknownChainId());
        return 0;
    }
}
