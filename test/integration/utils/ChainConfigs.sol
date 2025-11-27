// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.8.28;

import {IntegrationConstants} from "./IntegrationConstants.sol";

/// @title ChainConfigs
/// @notice Centralized configuration for multi-chain fork testing
/// @dev Follows MigrationV3_1.t.sol pattern: single ALCHEMY_API_KEY for all Alchemy chains, separate PLUME_API_KEY
/// @dev Usage: string.concat("https://", config.alchemyNetworkId, "-mainnet.g.alchemy.com/v2/", vm.envString("ALCHEMY_API_KEY"))
library ChainConfigs {
    struct ChainConfig {
        string name;
        string alchemyNetworkId; // Network ID for Alchemy (e.g., "eth", "base", "arb"). Empty for non-Alchemy chains (Plume).
        uint16 centrifugeId;
        uint16 wormholeId;
        string axelarId; // Empty string if not supported
        uint32 layerZeroEid;
        address usdc;
        address poolAdmin;
        address adminSafe;
        bool hasAxelar;
        bool hasLayerZero;
    }

    /// @notice Returns configuration for all supported chains
    function getAllChains() internal pure returns (ChainConfig[6] memory) {
        return [
            ChainConfig({
                name: "Ethereum",
                alchemyNetworkId: "eth",
                centrifugeId: IntegrationConstants.ETH_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.ETH_WORMHOLE_ID,
                axelarId: IntegrationConstants.ETH_AXELAR_ID,
                layerZeroEid: IntegrationConstants.ETH_LAYERZERO_EID,
                usdc: IntegrationConstants.ETH_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.ETH_ADMIN_SAFE,
                hasAxelar: true,
                hasLayerZero: true
            }),
            ChainConfig({
                name: "Base",
                alchemyNetworkId: "base",
                centrifugeId: IntegrationConstants.BASE_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.BASE_WORMHOLE_ID,
                axelarId: IntegrationConstants.BASE_AXELAR_ID,
                layerZeroEid: IntegrationConstants.BASE_LAYERZERO_EID,
                usdc: IntegrationConstants.BASE_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.BASE_ADMIN_SAFE,
                hasAxelar: true,
                hasLayerZero: true
            }),
            ChainConfig({
                name: "Arbitrum",
                alchemyNetworkId: "arb",
                centrifugeId: IntegrationConstants.ARBITRUM_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.ARBITRUM_WORMHOLE_ID,
                axelarId: IntegrationConstants.ARBITRUM_AXELAR_ID,
                layerZeroEid: IntegrationConstants.ARBITRUM_LAYERZERO_EID,
                usdc: IntegrationConstants.ARBITRUM_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.ARBITRUM_ADMIN_SAFE,
                hasAxelar: true,
                hasLayerZero: true
            }),
            ChainConfig({
                name: "Avalanche",
                alchemyNetworkId: "avax",
                centrifugeId: IntegrationConstants.AVAX_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.AVAX_WORMHOLE_ID,
                axelarId: IntegrationConstants.AVAX_AXELAR_ID,
                layerZeroEid: IntegrationConstants.AVAX_LAYERZERO_EID,
                usdc: IntegrationConstants.AVAX_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.AVAX_ADMIN_SAFE,
                hasAxelar: true,
                hasLayerZero: true
            }),
            ChainConfig({
                name: "BNB",
                alchemyNetworkId: "bnb",
                centrifugeId: IntegrationConstants.BNB_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.BNB_WORMHOLE_ID,
                axelarId: IntegrationConstants.BNB_AXELAR_ID,
                layerZeroEid: IntegrationConstants.BNB_LAYERZERO_EID,
                usdc: IntegrationConstants.BNB_USDC,
                poolAdmin: IntegrationConstants.ETH_DEFAULT_POOL_ADMIN,
                adminSafe: IntegrationConstants.BNB_ADMIN_SAFE,
                hasAxelar: true,
                hasLayerZero: true
            }),
            ChainConfig({
                name: "Plume",
                alchemyNetworkId: "", // Plume doesn't use Alchemy
                centrifugeId: IntegrationConstants.PLUME_CENTRIFUGE_ID,
                wormholeId: IntegrationConstants.PLUME_WORMHOLE_ID,
                axelarId: "", // Plume doesn't support Axelar
                layerZeroEid: 0, // Plume doesn't support LayerZero
                usdc: IntegrationConstants.PLUME_PUSD, // pUSD instead of USDC until USDC exists
                poolAdmin: IntegrationConstants.PLUME_POOL_ADMIN,
                adminSafe: IntegrationConstants.PLUME_ADMIN_SAFE,
                hasAxelar: false,
                hasLayerZero: false
            })
        ];
    }

    /// @notice Returns configuration for a specific chain by name
    function getChainConfig(string memory chainName) internal pure returns (ChainConfig memory) {
        ChainConfig[6] memory configs = getAllChains();
        for (uint256 i = 0; i < configs.length; i++) {
            if (keccak256(bytes(configs[i].name)) == keccak256(bytes(chainName))) {
                return configs[i];
            }
        }
        revert("Chain configuration not found");
    }

    /// @notice Returns configuration for a specific chain by centrifuge ID
    function getChainConfigById(uint16 centrifugeId) internal pure returns (ChainConfig memory) {
        ChainConfig[6] memory configs = getAllChains();
        for (uint256 i = 0; i < configs.length; i++) {
            if (configs[i].centrifugeId == centrifugeId) {
                return configs[i];
            }
        }
        revert("Chain configuration not found");
    }

    /// @notice Builds RPC URL for a chain using ALCHEMY_API_KEY or PLUME_API_KEY
    function getRpcUrl(ChainConfig memory config, bool isMainnet) internal pure returns (string memory) {
        // Alchemy-supported chains
        if (bytes(config.alchemyNetworkId).length > 0) {
            string memory env = isMainnet ? "-mainnet" : "-sepolia";
            return string.concat("https://", config.alchemyNetworkId, env, ".g.alchemy.com/v2/{ALCHEMY_API_KEY}");
        }

        // Plume uses its own RPC (mainnet only)
        if (config.centrifugeId == IntegrationConstants.PLUME_CENTRIFUGE_ID) {
            require(isMainnet, "Plume testnet not supported");
            return "https://rpc.plume.org/{PLUME_API_KEY}";
        }

        revert("Unsupported chain for RPC URL generation");
    }
}
