# Spell Validation Framework

Validates Centrifuge protocol state before and after executing governance spells. Queries the GraphQL indexer to ensure no blocking operations exist (PRE) and that state is correctly preserved (POST).

## Architecture

```
test/integration/spell/
├── utils/
│   └── validation/                      # Framework (shared)
│       ├── BaseValidator.sol            # Abstract base with ValidationContext + helpers
│       ├── ValidationExecutor.sol       # Runs validators and displays report
│       ├── TestContracts.sol            # TestContracts struct + factory functions
│       └── InvestmentFlowExecutor.sol   # Investment flow execution for fork tests
└── example-spell/                       # Example usage
    ├── ExampleTest.t.sol                # Example test wiring PRE/cache/POST phases
    └── validators/
        └── Validate_Example.sol         # Example: PRE query, cache, POST read
```

## Validation Flow

### PRE/POST Pattern

```solidity
contract MySpellTest {
    BaseValidator[] pre;
    BaseValidator[] cache;
    BaseValidator[] post;

    constructor() {
        pre.push(new Validate_YourPreCheck());
        cache.push(new Validate_YourCacheCheck());
        post.push(new Validate_YourPostCheck());
    }

    function testSpell() public {
        ValidationExecutor executor = new ValidationExecutor("ethereum");

        // 1. PRE validation (soft failures = warnings)
        executor.runPreValidation(pre, false);

        // 2. Cache validation (silent, no report)
        executor.runCacheValidation(cache);

        // 3. Execute spell
        spell.execute();

        // 4. POST validation (hard failures = reverts)
        executor.runPostValidation(post, testContractsFromConfig(Env.load("ethereum")));
    }
}
```

PRE validators query live state and cache results. Cache validators run silently to store data without reporting. POST validators read cached data and compare with the newly deployed contracts.

### ValidationContext

Every validator receives a `ValidationContext` with:

| Field              | Description                                      |
| ------------------ | ------------------------------------------------ |
| `contracts.live`   | Current deployed addresses (from `env/*.json`)   |
| `contracts.latest` | Newly deployed contracts (empty for PRE phase)   |
| `localCentrifugeId`| Chain's centrifuge ID                            |
| `indexer`          | `GraphQLQuery` instance for the chain's API      |
| `cache`            | `CacheStore` for cross-phase data persistence    |
| `isMainnet`        | Whether the chain is mainnet                     |

## Adding a Validator

### 1. Create Validator Contract

Create a validator contract (e.g., `test/integration/spell/your-spell/validators/Validate_YourCheck.sol`):

```solidity
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {BaseValidator, ValidationContext} from "../../validation/BaseValidator.sol";

contract Validate_YourCheck is BaseValidator("YourCheck") {
    using stdJson for string;

    function validate(ValidationContext memory ctx) public override {
        string memory query = "yourEntity(limit: 1000) { items { id field1 } totalCount }";
        string memory json = ctx.indexer.queryGraphQL(query);

        uint256 totalCount = json.readUint(".data.yourEntity.totalCount");

        for (uint256 i = 0; i < totalCount; i++) {
            uint256 field1 = json.readUint(".data.yourEntity.items".asJsonPath(i, "field1"));

            if (field1 != 0) {
                _errors.push(_buildError({
                    field: "field1",
                    value: string.concat("Item ", vm.toString(i)),
                    expected: "0",
                    actual: vm.toString(field1),
                    message: "Field1 should be zero"
                }));
            }
        }
    }
}
```

### 2. Register in Your Test

Add validators to the appropriate phase array in your test contract:

```solidity
import {Validate_YourCheck} from "./validators/Validate_YourCheck.sol";

// In the constructor:
pre.push(new Validate_YourCheck());   // for pre-spell checks
cache.push(new Validate_YourCheck()); // for silent caching
post.push(new Validate_YourCheck());  // for post-spell checks
```

## Caching Data Between Phases

PRE validators can cache GraphQL results for POST validators to compare against deployed state:

```solidity
// PRE validator: query and cache
function validate(ValidationContext memory ctx) public override {
    string memory json = ctx.indexer.queryGraphQL("pools(limit: 1000) { ... }");
    ctx.cache.set("pools", json);
}

// POST validator: read cached data
function validate(ValidationContext memory ctx) public override {
    string memory json = ctx.cache.get("pools");
    // Compare with ctx.contracts.latest...
}
```

Cache files are stored under `spell-cache/validation/<network>/` with filenames derived from the key.

## JSON Parsing

Use `stdJson` helpers per field. Do **not** use `vm.parseJson` + `abi.decode` which fails silently with mixed-type structs:

```solidity
// Parse fields individually
uint256 totalCount = json.readUint(".data.items.totalCount");
for (uint256 i = 0; i < totalCount; i++) {
    items[i].field1 = json.readUint(".data.items".asJsonPath(i, "field1"));
    items[i].field2 = json.readString(".data.items".asJsonPath(i, "field2"));
}
```

## TestContracts

`TestContracts` wraps `NonCoreReport` (main contracts) and `AdaptersReport` (adapter contracts). Two factory functions build it from different sources:

```solidity
// From a FullDeployer instance (test deployments)
TestContracts memory tc = testContractsFromDeployer(deployer);

// From an EnvConfig (existing on-chain addresses)
TestContracts memory tc = testContractsFromConfig(config);
```
