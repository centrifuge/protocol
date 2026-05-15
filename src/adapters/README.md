# Adapters

Adapters enable cross-chain messaging by integrating with various bridging protocols. Each adapter implements the `IAdapter` interface and handles message sending to destination chains while receiving messages from source chains via protocol-specific callbacks. The `MultiAdapter` uses multiple adapters with quorum-based verification for secure cross-chain communication.

## Contracts

### `LayerZeroAdapter`

`LayerZeroAdapter` integrates with LayerZero V2 for cross-chain messaging. The adapter uses LayerZero's endpoint V2 with configurable delegate for DVN (Decentralized Verifier Network) and executor settings, as well as send/receive library configuration. Message ordering is not enforced.

### `WormholeAdapter`

`WormholeAdapter` integrates with the Wormhole Relayer service for cross-chain messaging. The adapter identifies its local chain using the Wormhole delivery provider's chain ID and maintains source/destination mappings for routing.

### `AxelarAdapter`

`AxelarAdapter` integrates with Axelar Network for cross-chain messaging. The adapter uses Axelar's gas service to prepay for destination chain execution and validates incoming messages via the Axelar gateway's approval mechanism.

### `ChainlinkAdapter`

`ChainlinkAdapter` integrates with Chainlink CCIP for cross-chain messaging. The adapter uses the CCIP `Router` to dispatch messages with a per-destination gas limit (encoded in `GenericExtraArgsV2`) and validates incoming messages via the `ccipReceive` callback, accepting only the configured router as the caller. Replay protection is enforced by the CCIP stack, which tracks delivered message IDs.

### `HyperlaneAdapter`

`HyperlaneAdapter` integrates with the Hyperlane Mailbox for cross-chain messaging. Destination gas limits are encoded in `StandardHookMetadata` passed to the Mailbox's dispatch/quoteDispatch calls, and an admin-configurable Interchain Security Module (ISM) verifies inbound messages. Replay protection is enforced by the Hyperlane Mailbox.

### `PolymerAdapter`

`PolymerAdapter` integrates with Polymer's event-proving protocol for cross-chain messaging. Outbound messages are emitted as `SendMessage` events on the source chain; inbound messages are submitted permissionlessly via `receiveMessage` and validated through the `CrossL2ProverV2` prover contract. Polymer has no on-chain fee (relaying proofs and paying destination gas is handled off-chain), so the adapter enforces replay protection itself with per-source-chain nonces.

### `CCTPAdapter`

`CCTPAdapter` integrates with Circle's Cross-Chain Transfer Protocol (CCTP V2) generic messaging layer via the `MessageTransmitter`. Outbound messages are dispatched with `destinationCaller = 0` for permissionless relaying and a configurable `minFinalityThreshold` (default: finalized). Inbound messages are delivered by the destination `MessageTransmitter` through the `IMessageHandlerV2` callback after Circle's off-chain attestation service signs them. Replay protection is enforced by the `MessageTransmitter`'s consumed-nonce tracking, and the adapter rejects unfinalized (fast) deliveries.

### `RecoveryAdapter`

`RecoveryAdapter` is a special-purpose adapter for message recovery that allows authenticated parties to inject messages directly into the protocol entrypoint, bypassing normal cross-chain messaging. It implements both `IAdapter` and `IMessageHandler`, providing a direct path to the entrypoint while skipping any outgoing message sending (returns empty adapter data and zero cost estimates).
