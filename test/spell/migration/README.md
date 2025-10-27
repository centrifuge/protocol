# Pre-Migration Validation Framework

Validates Centrifuge protocol state before executing v3.0.1 to v3.1 migration spell. Queries the GraphQL indexer at https://api.centrifuge.io/ to ensure no pending operations exist that would be affected by the migration.

## Running Validation

```bash
forge test --match-contract PreMigrationValidation --ffi -vv
```

The test queries live data from the Centrifuge indexer and fails if any validation errors are found. Migration should NOT proceed until all validations pass.

## Current Validators

**EpochOutstandingInvests**: Checks that no pools have pending batch invest requests (epochOutstandingInvests.pendingAssetsAmount must be 0)

**EpochOutstandingRedeems**: Checks that no pools have pending batch redeem requests (epochOutstandingRedeems.pendingSharesAmount must be 0)

**OutstandingInvests**: Checks that no user-level invest requests exist with non-zero amounts in any of the 4 fields (pendingAmount, queuedAmount, depositAmount, approvedAmount)

**OutstandingRedeems**: Checks that no user-level redeem requests exist with non-zero amounts in any of the 4 fields

**CrossChainMessages**: Checks that all cross-chain messages are in "Executed" status (no AwaitingBatchDelivery, Failed, or Unsent messages)

## Adding New Validators

1. Create a new file in `test/spell/migration/validators/Validate_YourCheck.sol`

2. Extend BaseValidator and implement the validate() function:

```solidity
contract Validate_YourCheck is BaseValidator {
    function validate() public override returns (ValidationResult memory) {
        // Query GraphQL API
        string memory json = _queryGraphQL(
            '{"query": "{ yourQuery { items { field1 field2 } totalCount } }"}'
        );

        // Parse response
        uint256 totalCount = json.readUint(".data.yourQuery.totalCount");

        // Build errors if validation fails
        ValidationError[] memory errors = new ValidationError[](0);
        if (totalCount > 0) {
            // Create error with _buildError helper
        }

        return ValidationResult({
            passed: errors.length == 0,
            validatorName: "YourCheck",
            errors: errors
        });
    }
}
```

3. Register your validator in `PreMigrationValidation.t.sol`:

```solidity
function _initializeValidators() internal returns (BaseValidator[] memory) {
    BaseValidator[] memory validators = new BaseValidator[](6); // Increment size
    validators[0] = new Validate_EpochOutstandingInvests();
    validators[1] = new Validate_EpochOutstandingRedeems();
    validators[2] = new Validate_OutstandingInvests();
    validators[3] = new Validate_OutstandingRedeems();
    validators[4] = new Validate_CrossChainMessages();
    validators[5] = new Validate_YourCheck(); // Add your validator
    return validators;
}
```

## Implementation Notes

**JSON Parsing**: Do NOT use `vm.parseJson + abi.decode` for structs with mixed uint256/string fields. It fails silently. Use stdJson helpers instead:

```solidity
// BAD: abi.decode fails with mixed types
bytes memory raw = vm.parseJson(json, ".data.items");
MyStruct[] memory items = abi.decode(raw, (MyStruct[]));

// GOOD: Parse fields individually
MyStruct[] memory items = new MyStruct[](totalCount);
for (uint256 i = 0; i < totalCount; i++) {
    string memory path = string.concat(".data.items[", vm.toString(i), "]");
    items[i].field1 = json.readUint(string.concat(path, ".field1"));
    items[i].field2 = json.readString(string.concat(path, ".field2"));
}
```

**GraphQL Endpoint**: The API URL is defined in BaseValidator.GRAPHQL_API. Change it there if you need to point to a different environment (staging, testnet, etc).

**Error Formatting**: Use `_buildError()` helper for consistent error structure with field/value/expected/actual/message fields.

## Architecture

```
test/spell/migration/
├── BaseValidator.sol              # Abstract base with GraphQL + error helpers
├── PreMigrationValidation.t.sol   # Orchestrator that runs all validators
└── validators/
    ├── Validate_EpochOutstandingInvests.sol
    ├── Validate_EpochOutstandingRedeems.sol
    ├── Validate_OutstandingInvests.sol
    ├── Validate_OutstandingRedeems.sol
    └── Validate_CrossChainMessages.sol
```

Each validator is isolated in its own file to prevent merge conflicts when multiple developers add validators in parallel. The orchestrator automatically runs all registered validators and displays a detailed report.
