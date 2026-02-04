// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

/// @title GraphQLConstants
/// @notice Centralized GraphQL API endpoint constants
/// @dev Single source of truth for GraphQL URLs used across scripts and tests
library GraphQLConstants {
    string internal constant PRODUCTION_API = "https://api-v3-main-migration.cfg.embrio.tech";
    string internal constant TESTNET_API = "https://api-v3-test.cfg.embrio.tech";
}
