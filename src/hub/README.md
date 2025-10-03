# Hub

The Hub module in the Centrifuge Protocol serves as the core orchestration layer for decentralized pool management. It acts as the central controller that connects various components of a pool’s lifecycle - from registration and accounting to share class configuration and metadata handling.

![](https://docs.centrifuge.io/assets/images/hub-6be4376fec347560ff43a733f09f933f.png)

## Contracts

It contains six smart contracts:

### Hub

* **Description**: The central pool management contract.
* **Responsibilities**:

  * Aggregates and exposes all core pool functions in a single interface.
  * Allows pools to assign hub managers — trusted entities with full permissions over the pool lifecycle.
  * Coordinates pool creation, share class setup, metadata updates, and notification hooks.

### HubHelpers

* **Description**: Extension of the `Hub`.
* **Responsibilities**:

  * Additional functionality for the `Hub` contract.

### HubRegistry

* **Description**: A global registry of all pools, assets, and currencies used in the protocol.
* **Responsibilities**:

  * Stores `PoolId` objects mapped from external identifiers (e.g., Centrifuge IDs).
  * Enables canonical lookup of pools and related resources.
  * Ensures system-wide uniqueness and integrity of registered identifiers.

### Holdings

* **Description**: Ledger of holdings per pool, tied to accounting IDs.
* **Responsibilities**:

  * Tracks internal balances and positions for each pool.
  * Associates each holding with a unique accounting ID for traceability.

### Accounting

* **Description**: A robust double-entry bookkeeping system.
* **Responsibilities**:

  * Manages debits and credits across accounting IDs.
  * Ensures every operation maintains a balanced ledger.
  * Forms the financial backbone for audits and reporting.

### ShareClassManager

* **Description**: Manages share classes across pools and chains.
* **Responsibilities**:

  * Handles **epoch-based workflows**, including request submission, approval, and fulfillment.
  * Generates share class IDs and manages cross-chain state.