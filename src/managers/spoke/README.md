# Spoke Managers

Spoke managers provide specialized interfaces for balance sheet operations on spoke chains, including on/off-ramping for asset custody, merkle-proof-based permissioned operations for strategist workflows, and queue management for batched cross-chain synchronization.

![Spoke Managers architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/managers/spoke-managers.puml)

### `OnOfframpManager`

`OnOfframpManager` is a balance sheet manager for depositing and withdrawing ERC20 assets. Onramping (depositing assets into the pool) is permissionless once an asset is enabled—anyone can trigger the balance sheet deposit once ERC20 assets have been transferred to the manager. Offramping (withdrawing assets from the pool) is permissioned and requires predefined relayers to trigger withdrawals to predefined offramp accounts.

### `MerkleProofManager`

`MerkleProofManager` enables granular permissioned operations using merkle proofs, inspired by Boring Vaults. Strategists are assigned merkle root policies that define allowed operations as leaves in a merkle tree. Each strategist can execute arbitrary contract calls that match their policy by providing merkle proofs validating the operation against their assigned root.

The contract validates calls by extracting addresses from call data using decoder functions, constructing policy leaves (decoder, target, selector, value non-zero flag, addresses), and verifying merkle proofs against the strategist's root. This enables flexible, granular permissions without requiring on-chain storage of every allowed operation. Policies are updated via trusted contract updates from the Hub, allowing dynamic permission management. The manager can receive ETH for gas-paying operations and supports multiple calls in a single transaction.

### `QueueManager`

`QueueManager` manages the submission of queued assets and shares to the Hub, providing a batched interface for cross-chain state synchronization. It enforces minimum delay between sync operations to prevent spam when assets or shares can be permissionlessly modified (e.g., via onramp or sync deposits). The manager validates that queued amounts exist before triggering submissions and coordinates share submissions only when all queued assets for a share class have been submitted.