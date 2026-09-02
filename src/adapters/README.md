# Adapters

Adapters enable cross-chain messaging by integrating with various bridging protocols. Each adapter implements the `IAdapter` interface and handles message sending to destination chains while receiving messages from source chains via protocol-specific callbacks. The `MultiAdapter` uses multiple adapters with quorum-based verification for secure cross-chain communication.

## Contracts

### `LayerZeroAdapter`

`LayerZeroAdapter` integrates with LayerZero V2 for cross-chain messaging. The adapter uses LayerZero's endpoint V2 with configurable delegate for DVN (Decentralized Verifier Network) and executor settings, as well as send/receive library configuration. Message ordering is not enforced.

### `AxelarAdapter`

`AxelarAdapter` integrates with Axelar Network for cross-chain messaging. The adapter uses Axelar's gas service to prepay for destination chain execution and validates incoming messages via the Axelar gateway's approval mechanism.

### `ChainlinkAdapter`

`ChainlinkAdapter` integrates with Chainlink CCIP for cross-chain messaging. The adapter uses the CCIP `Router` to dispatch messages with a per-destination gas limit (encoded in `GenericExtraArgsV2`) and validates incoming messages via the `ccipReceive` callback, accepting only the configured router as the caller. Replay protection is enforced by the CCIP stack, which tracks delivered message IDs.

### `HyperlaneAdapter`

`HyperlaneAdapter` integrates with the Hyperlane Mailbox for cross-chain messaging. Destination gas limits are encoded in `StandardHookMetadata` passed to the Mailbox's dispatch/quoteDispatch calls, and an admin-configurable Interchain Security Module (ISM) verifies inbound messages. Replay protection is enforced by the Hyperlane Mailbox.
