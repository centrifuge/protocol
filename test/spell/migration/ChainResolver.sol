// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {MessageDispatcher} from "../../../src/core/messaging/MessageDispatcher.sol";

import {Root} from "../../../src/admin/Root.sol";

import {GraphQLConstants} from "../../../script/utils/GraphQLConstants.sol";

interface MessageDispatcherV3Like {
    function root() external view returns (Root root);
}

/// @title ChainResolver
/// @notice Initialize the context for a chain.
library ChainResolver {
    address constant PRODUCTION_MESSAGE_DISPATCHER_V3 = 0x21AF0C29611CFAaFf9271C8a3F84F2bC31d59132;
    address constant TESTNET_MESSAGE_DISPATCHER_V3 = 0x332bE89CAB9FF501F5EBe3f6DC9487bfF50Bd0BF;
    address constant TOKEN_FACTORY_V3 = 0xC8eDca090b772C48BcE5Ae14Eb7dd517cd70A32C;
    address constant ROUTER_ESCROW_V3 = 0xB86B6AE94E6d05AAc086665534A73fee557EE9F6;
    address constant GLOBAL_ESCROW_V3 = 0x43d51be0B6dE2199A2396bA604114d24383F91E9;

    /// @notice Chain context resolved from isMainnet flag
    struct ChainContext {
        address rootWard;
        address tokenFactory;
        address routerEscrow;
        address globalEscrow;
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
        address rootWard = isMainnet ? PRODUCTION_MESSAGE_DISPATCHER_V3 : TESTNET_MESSAGE_DISPATCHER_V3;
        uint16 localCentrifugeId = MessageDispatcher(rootWard).localCentrifugeId();
        Root rootV3 = MessageDispatcherV3Like(rootWard).root();
        string memory graphQLApi = isMainnet ? GraphQLConstants.PRODUCTION_API : GraphQLConstants.TESTNET_API;

        ctx = ChainContext({
            rootWard: rootWard,
            tokenFactory: TOKEN_FACTORY_V3,
            routerEscrow: ROUTER_ESCROW_V3,
            globalEscrow: GLOBAL_ESCROW_V3,
            localCentrifugeId: localCentrifugeId,
            rootV3: rootV3,
            graphQLApi: graphQLApi,
            isMainnet: isMainnet
        });
    }
}
