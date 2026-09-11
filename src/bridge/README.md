# Bridge

The bridge module exposes the protocol's cross-chain share transfers behind the interface generic token bridges expect. Third-party bridge frontends and aggregators integrate against `TokenBridge` and do not need to know about pools, share classes, or Centrifuge IDs: they name a token, an amount, a receiver, and a destination EVM chain ID, and the bridge resolves the rest from the spoke.

### `TokenBridge`

`TokenBridge` wraps `Spoke.crosschainTransferShares`. Its `send` translates the destination EVM chain ID into a Centrifuge ID through the `chainIdToCentrifugeId` mapping, resolves the pool and share class from the token address through `SpokeRegistry`, pulls the shares in from the caller, approves the `Spoke`, and forwards the transfer. Sends are rejected while the `Gateway` is batching, since the transfer has to settle its own cross-chain payment. The usual share transfer restrictions still apply: they are enforced downstream by the `Spoke`, which checks the share class registrar's `canBridge` and the owner's `bridger` role.

Gas limits for both legs are configured per pool and share class rather than passed by the caller, so an integrator never has to reason about Centrifuge gas accounting. They arrive from the hub: `fromHub` accepts calls only from the `Envoy`, rejects value, requires the share token to exist, and stores the pair of limits. The remaining wiring is governance-controlled through `file`, which sets the `relayer`, the `spoke`, the `gateway`, and the EVM-to-Centrifuge chain ID mapping.

The `relayer` exists to fund the second hop of a spoke to hub to spoke transfer. That path costs two payments, one on the source chain and one on the hub chain, but the user only ever pays once. The caller overpays the first leg and the excess is refunded to the relayer, which then covers the hub-side leg. When either endpoint is the hub the transfer is a single leg, so there is nothing for the relayer to fund and the overpayment goes back to the caller's refund address instead, as it also does when no relayer is configured.
