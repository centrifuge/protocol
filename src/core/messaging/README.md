# Messaging

The messaging module handles all cross-chain message serialization, dispatching, and processing in the Centrifuge Protocol. It provides a unified interface for outgoing messages, routes incoming messages to appropriate handlers, and manages gas estimation for cross-chain execution.

![Messaging architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/core/messaging.puml)

### `MessageDispatcher`

The `MessageDispatcher` serializes and dispatches outgoing cross-chain messages, handling both local and remote destinations. For local destinations (messages sent to the same chain), it directly invokes the appropriate handler to avoid unnecessary cross-chain overhead. For remote destinations, it routes messages through the `Gateway` and `MultiAdapter` to send them via configured cross-chain adapters.

### `MessageProcessor`

The `MessageProcessor` deserializes and processes incoming cross-chain messages, routing them to appropriate handlers based on message type. It validates source chains for privileged operations, ensuring that critical messages like pool creation or share class updates only come from trusted sources. The contract supports both paid and unpaid modes, with unpaid mode used for internal protocol messages that don't require gas payment validation.

The processor extracts message type and payload from incoming messages using `MessageLib`, then routes to handlers like `HubHandler`, `Spoke`, `BalanceSheet`, `VaultRegistry`, or `ContractUpdater` based on the message type. It enforces that certain privileged operations can only originate from the mainnet Centrifuge chain (ID 1), providing a security layer for critical protocol state changes. The contract also handles special message types like schedule authentication, token recovery, and request callbacks.

### `GasService`

The `GasService` stores gas limits (in gas units) for cross-chain message execution, providing adapters with information about how much gas to allocate for each message type on destination chains. Gas limits are benchmarked using `script/utils/benchmark.sh` and include a base cost covering adapter and gateway processing overhead plus the specific execution cost for each message type.

Each message type has an immutable gas limit set at deployment, covering operations from simple notifications (~100k gas) to complex vault deployments (~2.8M gas). The contract implements `IMessageLimits` to expose these values to the protocol, enabling accurate gas estimation for cross-chain operations. Gas values account for worst-case scenarios like creating new escrows during pool notifications or deploying and linking vaults in a single operation.
