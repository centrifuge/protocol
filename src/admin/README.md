# Admin

The admin module provides protocol governance and emergency controls, including timelocked permission management, pause functionality, cross-chain upgrade coordination, and token recovery. It separates operational duties (pool creation, adapter wiring) from protocol-level security controls (pausing, emergency recovery).

![Admin architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/admin.puml)

### `Root`

`Root` is the core administrative contract that holds ward permissions on all other deployed contracts in the protocol. It implements a timelock mechanism for granting new permissions while allowing instant pausing and permission revocation. Any contract that needs to be relied (granted ward permissions) must first be scheduled with a delay, then executed after the delay expires.

### `ProtocolGuardian`

`ProtocolGuardian` provides emergency controls and protocol-level management, including pausing, permission scheduling, cross-chain upgrade coordination, and adapter configuration. It acts as an intermediary between a multisig safe and the `Root` contract, providing a structured interface for protocol-wide operations. The contract supports instant pause by safe owners (for emergencies) and safe-only unpause to prevent unauthorized resumption.

### `OpsGuardian`

`OpsGuardian` manages operational aspects of the protocol, specifically adapter initialization, network wiring, and pool creation. It's controlled by an operations-focused multisig safe separate from the protocol guardian's safe, enabling separation of routine operations from critical protocol security decisions.

### `TokenRecoverer`

`TokenRecoverer` enables authorized recovery of tokens from protocol contracts by temporarily granting itself ward permissions through `Root`, executing the recovery via the target contract's `recoverTokens` function, and immediately removing those permissions. This atomic permission grant-execute-revoke pattern ensures the recoverer doesn't retain elevated privileges after operations.