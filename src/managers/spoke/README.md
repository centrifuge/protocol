# Spoke Managers

Spoke managers provide specialized interfaces for balance sheet operations on spoke chains, including on/off-ramping for asset custody and queue management for batched cross-chain synchronization.

![Spoke Managers architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/refs/heads/main/docs/architecture/managers/spoke-managers.puml)

### `OnOfframpManager`

`OnOfframpManager` is a balance sheet manager for depositing and withdrawing ERC20 assets. Onramping (depositing assets into the pool) is permissionless once an asset is enabled—anyone can trigger the balance sheet deposit once ERC20 assets have been transferred to the manager. Offramping (withdrawing assets from the pool) is permissioned and requires predefined relayers to trigger withdrawals to predefined offramp accounts.

### `QueueManager`

`QueueManager` manages the submission of queued assets and shares to the Hub, providing a batched interface for cross-chain state synchronization. It enforces minimum delay between sync operations to prevent spam when assets or shares can be permissionlessly modified (e.g., via onramp or sync deposits). The manager validates that queued amounts exist before triggering submissions and coordinates share submissions only when all queued assets for a share class have been submitted.