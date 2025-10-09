# Hub

The Hub module serves as the central orchestration layer for pool management in the Centrifuge Protocol. It coordinates all core pool operations including registration, accounting, holdings management, share class configuration, and cross-chain message handling.

![Hub architecture](http://www.plantuml.com/plantuml/proxy?cache=no&src=https://raw.githubusercontent.com/centrifuge/protocol/c8eba945b734afcabcead556b7c8c00561828268/docs/architecture/core/hub.puml)

### Hub

The central pool management contract that aggregates all core pool functions in a single interface.

**Key Responsibilities:**
- Pool administration and manager assignment
- Share class notifications and metadata updates
- Asset price broadcasting across chains
- Holdings initialization and updates
- Accounting coordination and double-entry bookkeeping
- Cross-chain message coordination via Gateway
- Fee hook integration for pool-level fee accrual

**Notable Features:**
- Managers have full rights over all pool actions
- Supports batched multicall operations
- Integrates with optional fee hooks for custom fee logic
- Coordinates with ShareClassManager, Holdings, Accounting, and HubRegistry

### HubHandler

Processes incoming cross-chain messages for the Hub, acting as the message receiver from the Gateway.

**Key Responsibilities:**
- Asset registration from remote chains
- Processing vault request callbacks
- Updating holding amounts based on cross-chain activity
- Handling share issuance and revocation messages
- Processing cross-chain share transfers
- Managing snapshot synchronization across chains

**Notable Features:**
- Auth-protected handlers called exclusively by the Gateway's MessageProcessor
- Coordinates state updates across Hub, Holdings, and ShareClassManager
- Validates and routes request callbacks to appropriate HubRequestManagers
- Maintains snapshot state for cross-chain consistency

### Holdings

Ledger of holdings per pool, tracking assets and their accounting associations.

**Key Responsibilities:**
- Initializing holdings with valuation contracts and account mappings
- Tracking holding amounts per pool, share class, and asset
- Increasing and decreasing holding amounts with price validation
- Computing pool-denominated values using IValuation contracts
- Managing snapshot state for cross-chain synchronization
- Optional ISnapshotHook integration for custom snapshot logic

**Notable Features:**
- Associates each holding with an IValuation for price conversion
- Supports liability vs. asset holdings
- Maintains snapshot state per chain to ensure data consistency
- Maps holdings to accounting IDs for double-entry bookkeeping

### HubRegistry

Global registry of all pools, assets, currencies, and pool-level dependencies.

**Key Responsibilities:**
- Registering pools with their initial manager and currency
- Registering assets with their decimal precision
- Managing pool managers (adding/removing)
- Storing pool metadata
- Managing pool dependencies (e.g., HubRequestManagers per chain)
- Validating pool and asset existence

**Notable Features:**
- Canonical source of truth for pool and asset registration
- Supports multiple managers per pool
- Tracks HubRequestManagers per pool and destination chain
- Enforces uniqueness of pools and assets

### Accounting

Double-entry bookkeeping system for all pool financial operations.

**Key Responsibilities:**
- Creating accounts with debit or credit normal balances
- Recording journal entries (debits and credits)
- Enforcing balanced transactions via lock/unlock mechanism
- Tracking account balances and last update timestamps
- Generating unique journal IDs per pool per transaction

**Notable Features:**
- Transient storage for in-flight journal state
- Requires unlock before entries, lock to commit
- Enforces debits equal credits invariant
- Supports account metadata for additional context
- Shares journal IDs across interleaved entries for the same pool

### ShareClassManager

Manages share classes across pools and chains, tracking issuance and metadata.

**Key Responsibilities:**
- Creating new share classes with unique IDs, names, symbols, and salts
- Tracking total issuance and per-chain issuance
- Updating share prices (price per share in pool currency)
- Managing share class metadata (name, symbol)
- Issuing and revoking shares based on cross-chain activity

**Notable Features:**
- Deterministic share class ID generation from pool and index
- Prevents salt reuse for share class uniqueness
- Tracks share issuance separately per chain
- Validates price timestamps to prevent future-dated prices
- Provides preview functions for next share class ID
