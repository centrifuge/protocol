# Project structure

```
src/
├── misc/              Generic contracts and utilities
├── core/              Core protocol infrastructure
│   ├── hub/           Hub module for pool management and accounting
│   ├── spoke/         Spoke module for local pool operations
│   └── messaging/     Cross-chain message dispatch and processing
├── libraries/         Shared utility libraries
├── adapters/          Cross-chain messaging adapters
├── admin/             Protocol governance and emergency controls
├── hooks/             Transfer restriction implementations
├── managers/          Extension managers
│   ├── hub/           Hub managers (NAV, pricing)
│   └── spoke/         Spoke managers (on/off-ramp, merkle proof, queue)
├── valuations/        Asset valuation implementations
└── vaults/            ERC-4626/ERC-7540 vault implementations
```

- **[`misc`](./misc)** - Generic contracts including Auth, ERC20, Escrow, math/cast libraries, and reentrancy protection
- **[`core/hub`](./core/hub)** - Hub module for centralized pool management, accounting, holdings, share class management, and registry
- **[`core/spoke`](./core/spoke)** - Spoke module for local pool operations, share tokens, balance sheets, vault registry, and pool escrows
- **[`core/messaging`](./core/messaging)** - Message serialization, dispatching, processing, and gas service for cross-chain communication
- **[`libraries`](./libraries)** - Shared utility libraries for message encoding, contract updates, and protocol operations
- **[`adapters`](./adapters)** - Cross-chain messaging adapters integrating with LayerZero, Wormhole, Axelar, and recovery mechanisms
- **[`admin`](./admin)** - Protocol governance with Root, ProtocolGuardian, OpsGuardian, and TokenRecoverer for timelocked permissions and emergency controls
- **[`hooks`](./hooks)** - Transfer hook implementations (FreezeOnly, RedemptionRestrictions, FullRestrictions, FreelyTransferable)
- **[`managers/hub`](./managers/hub)** - NAVManager for net asset value tracking and SimplePriceManager for single-share-class pool pricing
- **[`managers/spoke`](./managers/spoke)** - OnOfframpManager for asset custody, MerkleProofManager for permissioned operations, QueueManager for batched syncing
- **[`valuations`](./valuations)** - Asset valuation implementations (IdentityValuation for 1:1 pricing, OracleValuation for oracle-based pricing)
- **[`vaults`](./vaults)** - ERC-4626/ERC-7540 vault implementations (AsyncVault, SyncDepositVault), request managers, and router
