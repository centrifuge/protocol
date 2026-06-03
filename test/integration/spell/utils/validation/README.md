# Spell Validation Framework

Validates Centrifuge protocol state before and after executing governance spells. Queries the GraphQL indexer to ensure no blocking operations exist (PRE) and that state is correctly preserved (POST), and provides a spell-agnostic **environment regression** harness (`SpellRegressionTest`) that tolerates pre-existing live errors and fails only on regressions a spell introduces.

## Architecture

```
test/integration/spell/
├── utils/
│   ├── SpellRegressionTest.sol          # Abstract env-regression orchestrator for spells
│   ├── FlowRegression.sol               # Investment-flow regression mixin (query/snapshot/diff)
│   └── validation/                      # Framework (shared)
│       ├── BaseValidator.sol            # Abstract base with ValidationContext + helpers
│       ├── ValidationExecutor.sol       # Runs validators, reports, regression diff
│       ├── TestContracts.sol            # TestContracts struct + factory functions
│       └── InvestmentFlowExecutor.sol   # Investment flow execution for fork tests
├── example-spell/                       # Example: PRE/cache/POST wiring
│   ├── ExampleTest.t.sol
│   └── validators/
│       └── Validate_Example.sol
├── V2Cleanings.t.sol                    # Focused spell test (absolute post-state proof)
└── v2-cleanings/                        # Env regression for the same spell
    ├── V2CleaningsCast.sol              # Shared deploy + rely + cast() preamble
    ├── V2CleaningsValidatorTest.t.sol   # extends SpellRegressionTest
    └── validators/
        └── Validate_V2Cleanings.sol     # Pre (soft) / Cache / Post (hard) validators
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
        ValidationExecutor executor = new ValidationExecutor("ethereum", "my-spell");

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

**Migration spells (no new contracts):** use the `latest`-less overload `runPostValidation(post)` instead. It leaves `ctx.contracts.latest` as the zero struct, so a POST validator that erroneously reads `latest` fails loudly rather than silently aliasing the live set. The `latest`-taking overload remains for spells that actually deploy contracts.

### ValidationContext

Every validator receives a `ValidationContext` with:

| Field              | Description                                      |
| ------------------ | ------------------------------------------------ |
| `contracts.live`   | Current deployed addresses (from `env/*.json`)   |
| `contracts.latest` | Newly deployed contracts (empty for PRE phase and for migration-spell POST) |
| `localCentrifugeId`| Chain's centrifuge ID                            |
| `indexer`          | `GraphQLQuery` instance for the chain's API      |
| `cache`            | `CacheStore` for cross-phase data persistence    |
| `isMainnet`        | Whether the chain is mainnet                     |

## Spell Environment Regression (`SpellRegressionTest`)

A spell ships with **two tests**:

| Test | Extends | Purpose |
| ---- | ------- | ------- |
| `<Spell>.t.sol` (focused) | `Test` | Exhaustive forked correctness proof: cast + absolute post-state assertions (ward flips, `done()`, …) |
| `<spell>/<Spell>ValidatorTest.t.sol` | `SpellRegressionTest` | Environment regression: did the spell break anything *else* on the live network? |

Both call the same shared `<Spell>Cast` preamble (deploy + guardian relies + `cast()`) so they can never drift.

Per network, `SpellRegressionTest` runs three post-cast verification layers. All of them tolerate **pre-existing** live errors (live mainnet has known ones) and fail only on **regressions** the spell introduced:

1. **Structural validator diff** — the 8 live validators (`test/integration/fork/validators/`) run pre-cast (baseline) and post-cast. Error identity is `keccak256(validatorName | field | value)`; `actual` is deliberately excluded because it drifts (e.g. balances). Each post-cast error is classified `PRE-EXISTING` (tolerated), `REGRESSION` (fails), or `IMPROVED` (resolved by the spell).
2. **Spell-specific pre/cache/post validators** — the `example-spell/` pattern: PRE (soft warnings) + CACHE (file-backed snapshot for delta checks) run pre-cast; POST (hard) reads the cache + on-chain state post-cast.
3. **Investment-flow regression** — per-vault end-to-end deposit/redeem diff via the `FlowRegression` mixin. A vault that passed pre-cast and fails post-cast is a regression; pre-existing failures are logged and tolerated. Default-on; spells that don't touch vaults opt out.

Networks run isolated from each other: a failure on one network is recorded, the remaining networks still run, and the test fails at the end if any network failed.

### Adding a new spell (author guide)

1. **Focused spell test** at `test/integration/spell/<Spell>.t.sol` extending `Test`: fork, call the shared cast helper, assert the exact absolute post-state the spell guarantees.
2. **Shared cast preamble** at `test/integration/spell/<spell>/<Spell>Cast.sol` (library): deploy the spell, prank the guardian relies, `cast()`.
3. **Validators** at `test/integration/spell/<spell>/validators/Validate_<Spell>.sol`, mirroring `Validate_Example.sol` / `Validate_V2Cleanings.sol`:
   - `Validate_Pre<Spell>` (soft): assert there IS work to do.
   - `Validate_Cache<Spell>`: `ctx.cache.set(...)` the pre-cast values needed for delta checks.
   - `Validate_Post<Spell>` (hard): read the cache, assert the deltas + absolute invariants (`_checkWard` / `_checkNoWard`).
4. **Validator test** at `test/integration/spell/<spell>/<Spell>ValidatorTest.t.sol`:

```solidity
contract MySpellValidatorTest is SpellRegressionTest {
    function _networks() internal pure override returns (string[] memory networks) {
        networks = new string[](2);
        networks[0] = "ethereum";
        networks[1] = "base";
    }

    function _executorName() internal pure override returns (string memory) {
        return "myspell"; // cache namespace
    }

    function _castSpell(string memory, EnvConfig memory config) internal override {
        MySpellCast.deployAndCast(config);
    }

    function _preValidators() internal override returns (BaseValidator[] memory v) { ... }
    function _cacheValidators() internal override returns (BaseValidator[] memory v) { ... }
    function _postValidators() internal override returns (BaseValidator[] memory v) { ... }

    // Default true — override to false for spells that don't touch vaults
    // (e.g. adapter rewiring), where flow regression is irrelevant.
    function _runInvestmentFlowsDiff() internal pure override returns (bool) { return false; }
}
```

5. Run (fork tests need RPC keys): `set -a; . .env; set +a; forge test --match-contract MySpellValidatorTest -vv`

### Config-changing spells and the structural diff

`Validate_AdapterConfigurations` (and friends) compare on-chain state to the `env/` files. A spell that intentionally changes that state (e.g. swapping adapters) must update the `env/` file **in the same change** to the post-spell target. The diff then sees: pre-cast on-chain (old) vs env (new) = tolerated `PRE-EXISTING` mismatch; post-cast on-chain (new) vs env (new) = clean, reported as `IMPROVED`. A plain hard-fail POST would false-positive on the intended change — this is exactly why the diff mode exists.

### Legacy-codegen constraints (why the internals look the way they do)

The repo compiles with `optimizer_runs=1` and **no `via_ir`**. Legacy codegen cannot ABI-code deeply nested dynamic types (`ValidationResult[]`, `InvestmentFlowResult[]`, `EnvConfig`) across an `external` call without stack-too-deep. Consequences:

- The structural baseline never crosses an ABI boundary: `captureErrorBaseline(validators)` serializes error-identity keys into the **executor's own storage**, and `runValidationDiffPost(validators)` must be called on the **same executor instance** (which therefore survives the cast).
- Baseline capture is **not** snapshot-wrapped — a `vm.revertToState` would revert the executor's baseline storage write. The 8 structural validators are read-only, so no isolation is needed.
- `FlowRegression` is an **inherited mixin** (internal functions), not an externally-called helper.
- Pre-cast flow results are carried across the cast as `abi.encode`'d `bytes` in orchestrator storage (1 slot).
- `FlowRegression._parseBytes16` uses a loop, not assembly (equivalence pinned by `FlowRegression.t.sol`).

## Adding a Validator

### 1. Create Validator Contract

Create a validator contract (e.g., `test/integration/spell/your-spell/validators/Validate_YourCheck.sol`):

```solidity
// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {BaseValidator, ValidationContext} from "../../utils/validation/BaseValidator.sol";

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

`BaseValidator` ships reusable ward helpers: `_checkWard(target, holder, label)` asserts `holder` IS a ward on `target`; `_checkNoWard(target, holder, label)` asserts it is NOT (useful for spells that revoke permissions).

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

Cache files are stored under `spell-cache/validation/<executorName>/<network>/` with filenames derived from the key. The cache is file-backed, so values written pre-cast survive the spell cast within a test run. Plain (non-JSON) values work too: store with `vm.toString(value)` and read back with `vm.parseUint(...)` (see `Validate_CacheV2Cleanings`).

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
