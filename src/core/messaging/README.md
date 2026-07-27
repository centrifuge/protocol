# Messaging

The messaging module handles all cross-chain message serialization, dispatching, and processing in the Centrifuge Protocol. It provides a unified interface for outgoing messages, routes incoming messages to appropriate handlers, and manages gas estimation for cross-chain execution.

![Messaging architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/core/messaging.puml)

### `MessageDispatcher`

The `MessageDispatcher` serializes and dispatches outgoing cross-chain messages, handling both local and remote destinations. For local destinations (messages sent to the same chain), it directly invokes the appropriate handler to avoid unnecessary cross-chain overhead. For remote destinations, it routes messages through the `Gateway` and `MultiAdapter` to send them via configured cross-chain adapters.

### `MessageProcessor`

The `MessageProcessor` deserializes and processes incoming cross-chain messages, routing them to the appropriate handler based on message type. The contract supports both paid and unpaid modes, with unpaid mode used for internal protocol messages that don't require gas payment validation.

The processor extracts the message type and payload from incoming messages using `MessageLib`, then dispatches to the spoke handler (`ISpokeGatewayHandler`) or the hub handler (`IHubGatewayHandler`), plus a root branch for protocol-admin messages, based on the message type. It also handles special message types like schedule authentication (upgrade scheduling/cancellation) and request callbacks. Authentication of the message source is handled upstream by the `Gateway` and adapters, not by the processor.

### `GasService`

The `GasService` stores gas limits (in gas units) for cross-chain message execution, providing adapters with information about how much gas to allocate for each message type on destination chains. Gas limits are benchmarked using `script/utils/benchmarks.sh` and include a base cost covering adapter and gateway processing overhead plus the specific execution cost for each message type.

Each message type has an immutable gas limit set at deployment, covering operations from simple notifications (~100k gas) to complex vault deployments (~2.8M gas). The contract implements `IGasService` to expose these values to the protocol, enabling accurate gas estimation for cross-chain operations. Gas values account for worst-case scenarios like creating new escrows during pool notifications or deploying and linking vaults in a single operation.
