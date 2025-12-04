// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {V3Contracts} from "../../../../src/spell/migration_v3.1/MigrationSpell.sol";

/// @notice Extended old contracts struct with test-only fields
/// @dev Wraps PoolMigrationOldContracts to avoid polluting production code
struct V3ContractsExt {
    V3Contracts inner;
    address messageDispatcher;
}
