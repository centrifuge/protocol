# Spell Validation Framework

Validates Centrifuge protocol state before and after executing governance spells. Queries the GraphQL indexer to ensure no blocking operations exist (PRE) and that state is correctly preserved (POST).

## Architecture

```
test/spell/validation/
├── BaseValidator.sol            # Abstract base with ValidationContext + helpers
├── ValidationExecutor.sol       # Runs validators and displays report
├── ValidationSuite.sol          # Registers PRE/POST validators
├── TestContracts.sol            # TestContracts struct + factory functions
├── InvestmentFlowExecutor.sol   # Investment flow execution for fork tests
└── validators/
    └── Validate_Example.sol     # Example: PRE query, cache, POST read
```

## Validation Flow

### PRE/POST Pattern

```solidity
contract MySpellTest is ValidationSuite {
    ValidationSuite suite = new ValidationSuite("ethereum");

    function testSpell() public {
        // 1. PRE validation (soft failures = warnings)
        suite.runPreValidation(false);

        // 2. Execute spell
        spell.execute();

        // 3. POST validation (hard failures = reverts)
        suite.runPostValidation(testContractsfromDeployer(deployer));
    }
}
```

PRE validators query live state and cache results. POST validators read cached data and compare with the newly deployed contracts.

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

Create `test/spell/validation/validators/Validate_YourCheck.sol`:

```solidity
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {BaseValidator, ValidationContext} from "../BaseValidator.sol";

contract Validate_YourCheck is BaseValidator("YourCheck") {
    using stdJson for string;

    function validate(ValidationContext memory ctx) public override {
        string memory query = "yourEntity(limit: 1000) { items { id field1 } totalCount }";
        string memory json = ctx.indexer.queryGraphQL(query);

        uint256 totalCount = json.readUint(".data.yourEntity.totalCount");

        for (uint256 i = 0; i < totalCount; i++) {
            uint256 field1 = json.readUint(_buildJsonPath(".data.yourEntity.items", i, "field1"));

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

### 2. Register in ValidationSuite

Edit `ValidationSuite.sol`:

```solidity
import {Validate_YourCheck} from "./validators/Validate_YourCheck.sol";

// In runPreValidation():
executor.add(new Validate_YourCheck());

// Or in runPostValidation():
executor.add(new Validate_YourCheck());
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
    items[i].field1 = json.readUint(_buildJsonPath(".data.items", i, "field1"));
    items[i].field2 = json.readString(_buildJsonPath(".data.items", i, "field2"));
}
```

## TestContracts

`TestContracts` wraps `NonCoreReport` (main contracts) and `AdaptersReport` (adapter contracts). Two factory functions build it from different sources:

```solidity
// From a FullDeployer instance (test deployments)
TestContracts memory tc = testContractsfromDeployer(deployer);

// From an EnvConfig (existing on-chain addresses)
TestContracts memory tc = testContractsfromConfig(config);
```
