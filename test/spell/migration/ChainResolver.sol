// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {Root} from "../../../src/admin/Root.sol";

/// @title ChainResolver
/// @notice Initialize the context for a chain.
library ChainResolver {
    /// @notice Chain context resolved from isMainnet flag
    struct ChainContext {
        address rootWard;
        uint16 localCentrifugeId;
        Root rootV3;
        string graphQLApi;
        bool isMainnet;
    }

    /// @notice Resolve chain context from isMainnet flag
    /// @dev Centralizes address resolution logic for v3.0.1 contracts
    /// @param isMainnet Whether this is production (mainnet) or testnet
    /// @return ctx ChainContext with resolved addresses and API endpoint
    function resolveChainContext(bool isMainnet) internal view returns (ChainContext memory ctx) {
        // TODO: resolve the chain context by using env/*.json files
    }
}
