# Project structure

```
src/
├── misc/              Generic contracts and utilities
├── core/              Core protocol infrastructure
│   ├── hub/           Hub module for pool management and accounting
│   ├── spoke/         Spoke module for local pool operations
│   ├── messaging/     Cross-chain message dispatch and processing
│   ├── types/         Shared value types (PoolId, ShareClassId, AssetId, ...)
│   ├── libraries/     Shared libraries (e.g. PricingLib)
│   └── utils/         Core utilities (BatchedMulticall, Envoy)
├── token/             Share token and transfer hooks
│   └── hooks/         Transfer restriction hooks
├── adapters/          Cross-chain messaging adapters
├── admin/             Protocol governance, emergency controls, and gas service
├── hooks/             Accounting and bridge hooks
│   ├── accounting/    NAVManager, SimplePriceManager
│   └── bridge/        BridgeCircuitBreaker
├── managers/          Extension managers
│   ├── hub/           Hub managers (Supervisor)
│   └── spoke/         Spoke managers (on/off-ramp, queue, guards)
├── policies/          Policy & timelock enforcement
│   └── hub/           StdHubPolicy
├── valuations/        Asset valuation implementations
├── vaults/            ERC-4626/ERC-7540 vault implementations
├── bridge/            TokenBridge for cross-chain token transfers
├── utils/             Gas-subsidy utilities (SubsidyManager, RefundEscrow)
├── deployment/        Deployment orchestration
└── spell/             On-chain migration spells
```

- **[`misc`](./misc)** - Generic contracts including Auth, ERC20, Escrow, math/cast libraries, and reentrancy protection
- **[`core/hub`](./core/hub)** - Hub module for centralized pool management, accounting, holdings, share class management, and registry
- **[`core/spoke`](./core/spoke)** - Spoke module for local pool operations, balance sheets, vault registration (`SpokeRegistry`), and pool escrows
- **[`core/messaging`](./core/messaging)** - Message serialization, dispatching, and processing for cross-chain communication
- **[`token`](./token)** - `ShareToken` (ERC20 + ERC1404), `ShareTokenRegistrar`, and the transfer restriction hooks under `token/hooks` (FreezeOnly, RedemptionRestrictions, FullRestrictions, FreelyTransferable)
- **[`adapters`](./adapters)** - Cross-chain messaging adapters integrating with LayerZero, Axelar, Chainlink, and Hyperlane
- **[`admin`](./admin)** - Protocol governance with Root, ProtocolGuardian, and OpsGuardian, plus the `GasService`
- **[`hooks`](./hooks)** - Accounting hooks (`NAVManager`, `SimplePriceManager`) and the bridge circuit breaker
- **[`managers/hub`](./managers/hub)** - `Supervisor`, the pool-scoped sentinel/veto layer for the authorize flow
- **[`managers/spoke`](./managers/spoke)** - `OnOffRamp` for asset custody, `QueueManager` for batched syncing, and balance-sheet guards
- **[`policies`](./policies)** - Policy and timelock enforcement layer, bounding what any manager call can do and delaying out-of-policy actions behind a sentinel veto window (`StdHubPolicy` under `policies/hub`)
- **[`valuations`](./valuations)** - Asset valuation implementations (IdentityValuation for 1:1 pricing, OracleValuation for oracle-based pricing)
- **[`vaults`](./vaults)** - ERC-4626/ERC-7540 vault implementations (AsyncVault, SyncDepositVault), request managers, and router
- **[`bridge`](./bridge)** - `TokenBridge` wrapper for cross-chain share-token transfers
- **[`utils`](./utils)** - Gas-subsidy utilities: `SubsidyManager` and per-pool `RefundEscrow`
- **[`deployment`](./deployment)** - Deployment orchestration (deployers and action batchers)
- **[`spell`](./spell)** - On-chain migration spells
