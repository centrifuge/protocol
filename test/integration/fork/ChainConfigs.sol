// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IntegrationConstants} from "../utils/IntegrationConstants.sol";

/// @title ChainConfigs
/// @notice Centralized configuration for multi-chain fork testing
library ChainConfigs {
    struct ChainConfig {
        string name;
        string envVarName;
        string publicRpc;
        uint16 centrifugeId;
        uint16 wormholeId;
        string axelarId; // Empty string if not supported
        address usdc;
        address poolAdmin;
        address adminSafe;
        bool hasAxelar;
    }

    /// @notice Returns configuration for all supported chains
    function getAllChains() internal pure returns (ChainConfig[6] memory) {
        return [
            ChainConfig({
                name: "Ethereum",
                envVarName: "ETH_RPC_URL",
                publicRpc: IntegrationConstants.RPC_ETHEREUM,
                centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.ETH_WORMHOLE_ID,
                axelarId: IntegrationConstants.ETH_AXELAR_ID,
                usdc: IntegrationConstants.ETH_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.ETH_ADMIN_SAFE,
                hasAxelar: true
            }),
            ChainConfig({
                name: "Base",
                envVarName: "BASE_RPC_URL",
                publicRpc: IntegrationConstants.RPC_BASE,
                centrifugeId: IntegrationConstants.BASE_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.BASE_WORMHOLE_ID,
                axelarId: IntegrationConstants.BASE_AXELAR_ID,
                usdc: IntegrationConstants.BASE_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.BASE_ADMIN_SAFE,
                hasAxelar: true
            }),
            ChainConfig({
                name: "Arbitrum",
                envVarName: "ARBITRUM_RPC_URL",
                publicRpc: IntegrationConstants.RPC_ARBITRUM,
                centrifugeId: IntegrationConstants.ARBITRUM_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.ARBITRUM_WORMHOLE_ID,
                axelarId: IntegrationConstants.ARBITRUM_AXELAR_ID,
                usdc: IntegrationConstants.ARBITRUM_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.ARBITRUM_ADMIN_SAFE,
                hasAxelar: true
            }),
            ChainConfig({
                name: "Avalanche",
                envVarName: "AVAX_RPC_URL",
                publicRpc: IntegrationConstants.RPC_AVALANCHE,
                centrifugeId: IntegrationConstants.AVAX_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.AVAX_WORMHOLE_ID,
                axelarId: IntegrationConstants.AVAX_AXELAR_ID,
                usdc: IntegrationConstants.AVA_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.AVAX_ADMIN_SAFE,
                hasAxelar: true
            }),
            ChainConfig({
                name: "BNB",
                envVarName: "BNB_RPC_URL",
                publicRpc: IntegrationConstants.RPC_BNB,
                centrifugeId: IntegrationConstants.BNB_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.BNB_WORMHOLE_ID,
                axelarId: IntegrationConstants.BNB_AXELAR_ID,
                usdc: IntegrationConstants.BNB_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.BNB_ADMIN_SAFE,
                hasAxelar: true
            }),
            ChainConfig({
                name: "Plume",
                envVarName: "PLUME_RPC_URL",
                publicRpc: IntegrationConstants.RPC_PLUME,
                centrifugeId: IntegrationConstants.PLUME_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.PLUME_WORMHOLE_ID,
                axelarId: "", // Plume doesn't support Axelar
                usdc: IntegrationConstants.PLUME_PUSD, // pUSD instead of USDC until USDC exists
                poolAdmin: IntegrationConstants.PLUME_POOL_ADMIN,
                adminSafe: IntegrationConstants.PLUME_ADMIN_SAFE,
                hasAxelar: false
            })
        ];
    }

    /// @notice Returns configuration for a specific chain by name
    function getChainConfig(string memory chainName) internal pure returns (ChainConfig memory) {
        ChainConfig[6] memory chains = getAllChains();

        bytes32 nameHash = keccak256(bytes(chainName));
        for (uint256 i = 0; i < chains.length; i++) {
            if (keccak256(bytes(chains[i].name)) == nameHash) {
                return chains[i];
            }
        }

        revert("Chain configuration not found");
    }
}
