# Migration Validation Framework

Validates Centrifuge protocol state before and after executing v3.0.1 to v3.1 migration. Queries the GraphQL indexer at https://api.centrifuge.io/ (mainnet) or https://api-v3-test.cfg.embrio.tech (testnet) to ensure no pending operations exist and that state is correctly preserved.

## Running Validation

**Full migration test with validation:**
```bash
# Run specific chain migration test (includes PRE and POST validation)
ALCHEMY_API_KEY=your_key forge test --match-test testMigrationEthereumMainnet --ffi -vv

# All migration tests
ALCHEMY_API_KEY=your_key forge test --match-contract MigrationV3_1Test --ffi -vv
```

The tests query live data from the Centrifuge indexer and display validation results. PRE validation shows warnings for blocking issues; POST validation reverts if state preservation fails.

## Architecture

```
test/spell/migration/validation/
├── ValidationOrchestrator.sol         # Orchestrates PRE/POST validation suites
├── BaseValidator.sol                  # Abstract base with ValidationContext + helpers
├── GraphQLStore.sol                   # Idempotent cache (memory or file-persisted)
└── validators/
    ├── Validate_ShareClassManager.sol          # PRE + POST: Verify share class counts
    ├── Validate_EpochOutstandingInvests.sol    # PRE: No pending batch invests
    ├── Validate_EpochOutstandingRedeems.sol    # PRE: No pending batch redeems
    ├── Validate_OutstandingInvests.sol         # PRE: No user invest requests
    ├── Validate_OutstandingRedeems.sol         # PRE: No user redeem requests
    └── Validate_CrossChainMessages.sol         # PRE: All messages executed
```

## Validation Flow

### In Tests (Single EVM Instance)

```solidity
// 1. Resolve chain context (addresses, centrifugeId, graphQLApi)
ValidationOrchestrator.ChainContext memory chain = ValidationOrchestrator.resolveChainContext(isMainnet);

// 2. Create shared MigrationQueries instance
MigrationQueries queryService = new MigrationQueries(chain.graphQLApi, chain.localCentrifugeId, isMainnet);

// 3. Build shared context (in-memory cache)
ValidationOrchestrator.SharedContext memory shared = ValidationOrchestrator.buildSharedContext(
    queryService,
    poolsToMigrate,
    chain,
    ""  // ← Empty = in-memory only
);

// 4. PRE validation (soft failures)
ValidationOrchestrator.runPreValidation(shared, false);

// 5. Execute migration
migration.migrate(address(deployer), migrationSpell, poolsToMigrate);

// 6. POST validation (hard failures - reverts on error)
ValidationOrchestrator.runPostValidation(shared, deployer);
```

### In Production Scripts (Separate Invocations)

**PRE Script** (`script/spell/migrate-pre-validation.sh`):
```solidity
// Resolve chain context and create query service
ValidationOrchestrator.ChainContext memory chain = ValidationOrchestrator.resolveChainContext(isMainnet);
MigrationQueries queryService = new MigrationQueries(chain.graphQLApi, chain.localCentrifugeId, isMainnet);

// Build context with file persistence, write to spell-cache/validation/*.json
ValidationOrchestrator.SharedContext memory shared = ValidationOrchestrator.buildSharedContext(
    queryService,
    pools,
    chain,
    "spell-cache/validation"  // ← File persistence enabled
);

ValidationOrchestrator.runPreValidation(shared, true);  // Revert on errors
```

**POST Script** (`script/spell/migrate-post-validation.sh`):
```solidity
// Read from spell-cache/validation/*.json, compare with deployed contracts
ValidationOrchestrator.ChainContext memory chain = ValidationOrchestrator.resolveChainContext(isMainnet);
MigrationQueries queryService = new MigrationQueries(chain.graphQLApi, chain.localCentrifugeId, isMainnet);

ValidationOrchestrator.SharedContext memory shared = ValidationOrchestrator.buildSharedContext(
    queryService,
    pools,
    chain,
    "spell-cache/validation"  // ← Read cached data (GraphQL queries skipped)
);

ValidationOrchestrator.runPostValidation(shared, deployer);  // Always reverts on errors
```

## Current Validators

### PRE-Migration Validators (GraphQL Queries)

**EpochOutstandingInvests**: Checks that no pools have pending batch invest requests
- Query: `epochOutstandingInvests(poolId: X)`
- Requirement: `pendingAssetsAmount == 0`
- Blocks migration if batches are in-flight

**EpochOutstandingRedeems**: Checks that no pools have pending batch redeem requests
- Query: `epochOutstandingRedeems(poolId: X)`
- Requirement: `pendingSharesAmount == 0`
- Blocks migration if batches are in-flight

**OutstandingInvests**: Checks that no user-level invest requests exist
- Query: `outstandingInvests(limit: 1000)`
- Requirement: All 4 fields (pending, queued, deposit, approved) must be 0
- Blocks migration if users have pending invests

**OutstandingRedeems**: Checks that no user-level redeem requests exist
- Query: `outstandingRedeems(limit: 1000)`
- Requirement: All 4 fields must be 0
- Blocks migration if users have pending redeems

**CrossChainMessages**: Checks that all cross-chain messages are executed
- Query: `outgoingMessages(limit: 1000)`
- Requirement: All messages have `status == "Executed"`
- Blocks migration if messages are stuck (AwaitingBatchDelivery, Failed, Unsent)

### POST-Migration Validators (On-Chain Comparison)

**ShareClassManager**: Verifies share class counts are preserved
- Compares: `old.shareClassManager.shareClassCount(poolId)` vs `new.shareClassManager.shareClassCount(poolId)`
- Ensures: State correctly migrated for all hub pools

## Adding New Validators

### 1. Create Validator Contract

Create `test/spell/migration/validation/validators/Validate_YourCheck.sol`:

```solidity
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {BaseValidator} from "../BaseValidator.sol";
import {stdJson} from "forge-std/StdJson.sol";

contract Validate_YourCheck is BaseValidator {
    using stdJson for string;

    // Declare which phases this validator supports
    function supportedPhases() public pure override returns (Phase) {
        return Phase.PRE;  // or Phase.POST or Phase.BOTH
    }

    // Implement validation logic
    function validate(ValidationContext memory ctx) public override returns (ValidationResult memory) {
        ValidationError[] memory errors = new ValidationError[](10);
        uint256 errorCount = 0;

        if (ctx.phase == Phase.PRE) {
            // PRE: Query GraphQL, cache results
            string memory json = ctx.store.query(
                "yourQuery { items { field1 field2 } totalCount }"
            );

            uint256 totalCount = json.readUint(".data.yourQuery.totalCount");

            for (uint256 i = 0; i < totalCount; i++) {
                uint256 field1 = json.readUint(_buildJsonPath(".data.yourQuery.items", i, "field1"));

                if (field1 != expectedValue) {
                    errors[errorCount++] = _buildError({
                        field: "field1",
                        value: string.concat("Item ", _toString(i)),
                        expected: _toString(expectedValue),
                        actual: _toString(field1),
                        message: "Field1 mismatch"
                    });
                }
            }
        } else {
            // POST: Retrieve cached data, compare with deployed contracts
            string memory json = ctx.store.get("yourQuery { ... }");

            // Compare cached GraphQL data with ctx.deployer.yourContract()
            IYourContract newContract = ctx.deployer.yourContract();
            // ... comparison logic
        }

        return ValidationResult({
            passed: errorCount == 0,
            validatorName: "YourCheck",
            errors: _trimErrors(errors, errorCount)
        });
    }
}
```

### 2. Register in ValidationOrchestrator

Edit `ValidationOrchestrator.sol`:

```solidity
import {Validate_YourCheck} from "./validators/Validate_YourCheck.sol";

function _buildPreSuite() private returns (ValidationSuite memory) {
    BaseValidator[] memory validators = new BaseValidator[](7);  // Increment size

    validators[0] = new Validate_EpochOutstandingInvests();
    validators[1] = new Validate_EpochOutstandingRedeems();
    validators[2] = new Validate_OutstandingInvests();
    validators[3] = new Validate_OutstandingRedeems();
    validators[4] = new Validate_CrossChainMessages();
    validators[5] = new Validate_ShareClassManager();
    validators[6] = new Validate_YourCheck();  // Add here

    return ValidationSuite({validators: validators});
}
```

## Key Patterns

### Accessing Old Contracts

Use the wrapper pattern to access old contract addresses:

```solidity
// Access old v3.0.1 contracts via ctx.old.inner
IShareClassManager oldScm = IShareClassManager(ctx.old.inner.shareClassManager);

// Access test-only fields directly
address root = ctx.old.root;
address messageDispatcher = ctx.old.messageDispatcher;
```

### GraphQL Store Usage

**PRE validators** - Query and cache:
```solidity
string memory json = ctx.store.query("myQuery { items { id } }");
// First call: Executes query, stores result
// Subsequent calls: Returns cached result
```

**POST validators** - Retrieve cached data:
```solidity
string memory json = ctx.store.get("myQuery { items { id } }");
// Returns data cached during PRE phase
// Reverts if data not found
```

### JSON Parsing (Important!)

**❌ WRONG** - `abi.decode` fails silently with mixed types:
```solidity
bytes memory raw = vm.parseJson(json, ".data.items");
MyStruct[] memory items = abi.decode(raw, (MyStruct[]));  // FAILS!
```

**✅ CORRECT** - Parse fields individually:
```solidity
uint256 totalCount = json.readUint(".data.items.totalCount");
MyStruct[] memory items = new MyStruct[](totalCount);

for (uint256 i = 0; i < totalCount; i++) {
    items[i].field1 = json.readUint(_buildJsonPath(".data.items", i, "field1"));
    items[i].field2 = json.readString(_buildJsonPath(".data.items", i, "field2"));
}
```

### Error Building

Use `_buildError()` for consistent formatting:

```solidity
errors[errorCount++] = _buildError({
    field: "shareClassCount",                      // What field failed
    value: string.concat("Pool ", _toString(poolId)),  // Identifier
    expected: _toString(expectedValue),            // Expected value
    actual: _toString(actualValue),                // Actual value
    message: "Share class count mismatch"          // Human-readable message
});
```

## File Persistence Details

### Cache Structure

When `cacheDir = "spell-cache/validation"`:

```
spell-cache/validation/
├── outstandingInvests.json      # From query "outstandingInvests(...)"
├── outstandingRedeems.json      # From query "outstandingRedeems(...)"
├── epochOutstandingInvests.json
├── epochOutstandingRedeems.json
└── crossChainMessages.json
```

Filenames extracted from query string (first word before `(`, `{`, or space).

### Cache Lifecycle

**PRE Phase**:
1. Clean existing `spell-cache/validation/` directory
2. Execute GraphQL queries via `ctx.store.query()`
3. Write results to `*.json` files
4. Also store in memory for immediate use

**POST Phase** (separate script invocation):
1. Read `*.json` files via `ctx.store.get()`
2. Load into memory
3. Compare with deployed v3.1 contracts

### Foundry Configuration

Required in `foundry.toml`:
```toml
fs_permissions = [
  { access = "read-write", path = "spell-cache" },
]
```

## Testing Best Practices

1. **Use in-memory for tests** - Pass `""` to `buildSharedContext` for speed
2. **Use file persistence for scripts** - Pass `"spell-cache/validation"` for cross-script communication
3. **PRE validation warnings** - Set `shouldRevert=false` to see all issues before blocking
4. **POST validation errors** - Always reverts to prevent incorrect migrations
5. **Multi-chain support** - Pass actual `localCentrifugeId` from chain being tested

## Troubleshooting

**"must return exactly one JSON value"**
- GraphQL query returned empty array
- Check `centrifugeId` matches the chain being queried
- Verify deployment exists in GraphQL API for that centrifugeId

**"cache miss - was PRE validation run?"**
- POST script couldn't find cached file
- Ensure PRE script ran successfully and wrote files
- Check `spell-cache/validation/` directory exists

**"vm.exists: path not allowed"**
- Filesystem permissions missing
- Add `{ access = "read-write", path = "spell-cache" }` to `foundry.toml`

**Diamond inheritance error**
- Don't make `GraphQLQuery` inherit from `Script` or `Test`
- Both inherit from `CommonBase`, creating diamond conflict
