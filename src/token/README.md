# Token

The token module holds the protocol's own share token standard and the registrar that deploys and operates it. The core spoke contracts never touch a share token directly: they reach it through the `IRegistrar` seam, so alternative share token standards can be plugged in per share class without changing core. Transfer restrictions live one level down, in [`hooks`](./hooks).

### `ShareToken`

`ShareToken` is an ERC20 extended with ERC1404 restriction checks and an optional external hook. Balance and restriction state share a slot: each account holds a `uint128` amount alongside 16 bytes of `hookData` that the hook interprets (for example memberlist expiry and a freeze bit). `hookDataOf` reads it, and `setHookData` is callable by a ward or by the hook itself.

Every balance change routes through the hook. `transfer`, `transferFrom`, `mint`, and `burn` call `onERC20Transfer` and revert with `RestrictionsFailed` unless it returns its own selector, so a hook can block a transfer outright. `authTransferFrom` is the privileged path: a ward moves tokens without an allowance and the hook is notified through `onERC20AuthTransfer`, whose result is not enforced. With no hook installed the token is unrestricted. The ERC1404 views (`detectTransferRestriction`, `checkTransferRestriction`) delegate to the hook's `checkERC20Transfer` and are what callers use to test a transfer before attempting it.

The token also carries the ERC-7575 share pointer, `vault[asset]`, and reports `IERC7575Share` from `supportsInterface`. Decimals are fixed at construction; name, symbol, and the hook are set afterwards through `file`. Total supply is capped at `type(uint128).max` so it always fits the packed balance.

### `ShareTokenRegistrar`

`ShareTokenRegistrar` implements `IRegistrar` for the `ShareToken` standard. It deploys tokens deterministically with CREATE2 and stays a ward on every token it creates, which is what lets the core contracts operate tokens without holding permissions on them. `Root` is relied on each new token as well. Because the address derives only from `decimals` and the salt, with name and symbol applied after deployment, `previewTokenAddress` can be computed before the token exists.

`mint`, `authTransferFrom`, `updateVault`, `updateMetadata`, and `updateRestriction` are auth-gated pass-throughs to the token or its hook. `burn` is the exception: it first pulls the tokens to the calling core contract and burns them there, so hooks observe the same flow shapes as they did when core contracts held token permissions themselves, with the spoke as the redemption or crosschain transfer source. `canBridge` answers the spoke's cross-chain check by encoding the destination `centrifugeId` as an address and running it through the token's restriction check.

Configuration arrives from the hub rather than locally. `fromHub` accepts calls only from the `Envoy`, resolves the share token from `(poolId, scId)` through `SpokeRegistry`, refuses if this registrar does not serve that share class, and then dispatches on a leading discriminant: `SetHook` swaps the transfer hook, `UpdateWard` grants or revokes a ward (never its own), and `SetVault` overrides the ERC-7575 pointer. That override validates declaratively against registry storage, requiring any non-zero pointer to be a currently linked vault belonging to the same pool, share class, and asset, so the pointer cannot diverge from the registry.
