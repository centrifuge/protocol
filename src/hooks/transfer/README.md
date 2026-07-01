# Transfer Hooks

Transfer hooks provide customizable transfer restriction logic for share tokens in the Centrifuge Protocol. They enable pools to enforce compliance requirements, manage memberlists, freeze accounts, and control which operations require whitelisting. All hooks implement the `ITransferHook` interface and integrate with `ShareToken` for transfer validation.

![Hooks architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/hooks.puml)

### `BaseTransferHook`

`BaseTransferHook` is an abstract base contract that provides memberlist management, account freezing capabilities, and cross-chain message handling for transfer restrictions. It encodes member validity and freeze status in the `hookData` structure (bytes16) stored per user in the share token, with the first 8 bytes (uint64) representing the memberlist valid-until timestamp and the least significant bit indicating freeze status.

### `FreezeOnly`

`FreezeOnly` is the simplest hook implementation that only enforces account freezing. It allows any non-frozen account to receive and transfer tokens without memberlist requirements. Frozen accounts are blocked from both sending and receiving tokens, providing a basic compliance tool for temporarily restricting account activity.

This hook is suitable for pools that want minimal restrictions with the ability to freeze accounts. It uses only the freeze bit of the `hookData` structure, leaving memberlist functionality unused.

### `RedemptionRestrictions`

`RedemptionRestrictions` requires accounts to be added as members before submitting redemption requests, while allowing unrestricted deposits and transfers. It enforces freeze checks for all operations and validates memberlist membership only when tokens move from a user to the redeem source (indicating a redemption request).

This hook enables pools to maintain KYC/AML compliance for investors exiting positions while keeping deposits and secondary trading frictionless. It's useful for pools that want to verify investor identity before allowing withdrawals but don't want to restrict entry or token transfers.

### `FullRestrictions`

`FullRestrictions` requires adding accounts to the memberlist before they can receive tokens in most scenarios. It enforces the strictest compliance model, checking memberlist validity for deposit requests, deposit claims, cross-chain transfer executions, and general transfers. Only fulfillment operations (where vaults issue/burn tokens) and redemption claims bypass memberlist checks.

The hook provides comprehensive transfer control, ensuring that tokens only flow to whitelisted addresses except in system-level operations. It distinguishes between deposit requests (user → vault), deposit fulfillment (vault → user from escrow), deposit claims (escrow → user), redemption requests (user → vault), redemption fulfillment (vault burning), redemption claims (user receiving assets), and cross-chain operations, applying memberlist checks where appropriate.

### `FreelyTransferable`

`FreelyTransferable` allows unrestricted transfers without memberlist or freeze requirements. It always returns `true` for transfer checks, providing an opt-out from restrictions while maintaining the hook infrastructure for potential future upgrades.

This hook is suitable for fully permissionless pools or testing environments where compliance restrictions aren't needed. It still inherits the base infrastructure for memberlist and freeze management but doesn't enforce any restrictions by default.
