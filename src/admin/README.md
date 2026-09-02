# Admin

The admin module provides protocol governance and emergency controls, including timelocked permission management, pause functionality, and cross-chain upgrade coordination. It separates operational duties (pool creation, adapter wiring) from protocol-level security controls (pausing, spell-based token recovery).

![Admin architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/admin.puml)

### `Root`

`Root` is the core administrative contract that holds ward permissions on all other deployed contracts in the protocol. It implements a timelock mechanism for granting new permissions while allowing instant pausing and permission revocation. Any contract that needs to be relied (granted ward permissions) must first be scheduled with a delay, then executed after the delay expires.

### `ProtocolGuardian`

`ProtocolGuardian` provides emergency controls and protocol-level management, including pausing, permission scheduling, cross-chain upgrade coordination, and adapter configuration. It acts as an intermediary between a multisig safe and the `Root` contract, providing a structured interface for protocol-wide operations. The contract supports instant pause by safe owners (for emergencies) and safe-only unpause to prevent unauthorized resumption.

### `OpsGuardian`

`OpsGuardian` manages operational aspects of the protocol, specifically adapter initialization, network wiring, and pool creation. It's controlled by an operations-focused multisig safe separate from the protocol guardian's safe, enabling separation of routine operations from critical protocol security decisions.

### `GasService`

The `GasService` stores gas limits (in gas units) for cross-chain message execution, providing adapters with information about how much gas to allocate for each message type on destination chains. Gas limits are benchmarked using `script/checks/benchmarks.sh` and include a base cost covering adapter and gateway processing overhead plus the specific execution cost for each message type.

Each message type has an immutable gas limit set at deployment, covering operations from simple notifications (~100k gas) to complex vault deployments (~2.8M gas). The contract implements `IGasService` to expose these values to the protocol, enabling accurate gas estimation for cross-chain operations. Gas values account for worst-case scenarios like creating new escrows during pool notifications or deploying and linking vaults in a single operation.
