# Adapters

Adapters enable cross-chain messaging by integrating with various bridging protocols. Each adapter implements the `IAdapter` interface and handles message sending to destination chains while receiving messages from source chains via protocol-specific callbacks. The `MultiAdapter` uses multiple adapters with quorum-based verification for secure cross-chain communication.

## Contracts

### `LayerZeroAdapter`

`LayerZeroAdapter` integrates with LayerZero V2 for cross-chain messaging. The adapter uses LayerZero's endpoint V2 with configurable delegate for DVN (Decentralized Verifier Network) and executor settings, as well as send/receive library configuration. Message ordering is not enforced.

### `WormholeAdapter`

`WormholeAdapter` integrates with the Wormhole Relayer service for cross-chain messaging. The adapter identifies its local chain using the Wormhole delivery provider's chain ID and maintains source/destination mappings for routing.

### `AxelarAdapter`

`AxelarAdapter` integrates with Axelar Network for cross-chain messaging. The adapter uses Axelar's gas service to prepay for destination chain execution and validates incoming messages via the Axelar gateway's approval mechanism.

### `RecoveryAdapter`

`RecoveryAdapter` is a special-purpose adapter for message recovery that allows authenticated parties to inject messages directly into the protocol entrypoint, bypassing normal cross-chain messaging. It implements both `IAdapter` and `IMessageHandler`, providing a direct path to the entrypoint while skipping any outgoing message sending (returns empty adapter data and zero cost estimates).
