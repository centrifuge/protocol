# Hub Managers

Hub managers provide higher-level abstractions for pool management on the Hub, including NAV (Net Asset Value) tracking, accounting integration, and share price calculation for single-share-class pools. These managers coordinate with `Holdings`, `Accounting`, and `ShareClassManager` to maintain pool financial state.

![Hub Managers architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/managers/hub-managers.puml)

### `NAVManager`

`NAVManager` abstracts accounting of net asset value (NAV) for pools. It implements `ISnapshotHook` to receive callbacks when spokes reach snapshot state or when shares are transferred, triggering NAV calculations. The manager creates and manages accounting accounts per network (equity, liability, gain, loss) and initializes holdings with appropriate account mappings. The contract assumes all assets in a pool are shared across all share classes rather than being segregated.

### `SimplePriceManager`

`SimplePriceManager` calculates share prices for single-share-class pools based on NAV and total share issuance. It implements `INAVHook` to receive NAV updates from `NAVManager` and automatically computes and broadcasts share prices to configured networks. The contract maintains aggregate metrics (total issuance and NAV) across all networks and tracks per-network metrics for incremental updates. When NAV updates occur, the manager recalculates the pool-wide share price (NAV / total shares) and notifies all registered networks of the new price.