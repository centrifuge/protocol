# Hub Managers

Hub managers are pool-scoped contracts registered as managers on the Hub to provide governance and oversight around the authorization (policy) flow.

![Hub Managers architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/managers/hub-managers.puml)

### `Supervisor`

`Supervisor` is a pool-scoped sentinel registry and veto layer for the authorize flow. It holds no positive power of its own; its sole job is to let the sentinels it tracks veto a pending authorization during the policy delay window. It is registered as a Hub manager for its pool only so it can reach `IHub.cancelAuthorization` on behalf of sentinels (which are not themselves Hub managers). The hub, pool, and contract updater are immutable; the sentinel set is managed via `IHub.managerCall` through the pool's Envoy path.

### `SupervisorFactory`

`SupervisorFactory` deploys a `Supervisor` per pool at a deterministic, previewable CREATE2 address derived from `(poolId, envoy)` (the `hub` is a factory immutable). This lets a pool's supervisor address be computed ahead of deployment.
