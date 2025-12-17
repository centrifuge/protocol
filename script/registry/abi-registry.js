#!/usr/bin/env node
/**
 * @fileoverview Generates a delta contract registry JSON file containing ABIs and chain deployment metadata.
 * 
 * This script generates "delta registries" - registries that only contain contracts that have
 * changed since the previous version. Each delta registry includes a pointer to the previous
 * registry's IPFS hash, allowing indexers to walk backwards through the version chain.
 * 
 * This script:
 * 1. Fetches the current live registry from registry.centrifuge.io to compare against
 * 2. Reads chain configurations from env/*.json files
 * 3. Compares contracts to detect changes (new or modified addresses/blockNumbers)
 * 4. Fetches contract creation block numbers from Etherscan API (v2) for changed contracts
 * 5. Extracts ABIs from Forge build artifacts (only for changed contracts)
 * 6. Combines into a delta registry with previousRegistry pointer
 * 
 * Usage:
 *   DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> node script/registry/abi-registry.js [mainnet|testnet]
 * 
 * Environment Variables:
 *   - DEPLOYMENT_COMMIT: Git commit hash used to build the ABIs (required in CI)
 *   - ETHERSCAN_API_KEY: API key for Etherscan v2 API (required for block number fetching)
 * 
 * Output files:
 *   - mainnet: registry/registry-mainnet.json
 *   - testnet: registry/registry-testnet.json
 * 
 * Output: A JSON file with structure:
 *   {
 *     network: "mainnet" | "testnet",
 *     version: "3.1",
 *     deploymentInfo: { gitCommit: "...", startBlock: ... },
 *     previousRegistry: { version: "3.0", ipfsHash: null }, // ipfsHash filled by pin-to-ipfs.js
 *     abis: { ContractName: [...], ... },
 *     chains: { chainId: { network, adapters, contracts, deployment }, ... }
 *   }
 * 
 * Note: The previousRegistry.ipfsHash is set to null here and filled in by pin-to-ipfs.js
 * which queries Pinata for the CID of the previous registry.
 */

import {
    readFileSync,
    writeFileSync,
    readdirSync,
    mkdirSync,
    existsSync,
} from "fs";
import { dirname, join } from "path";

// Environment selector: "mainnet" or "testnet" (defaults to "mainnet")
const selector = process.argv.length > 2 ? process.argv.at(-1) : "mainnet";

// Git commit hash of the codebase version used to build ABIs (set by CI workflow)
const deploymentCommitOverride = process.env.DEPLOYMENT_COMMIT || null;

// Etherscan API key for fetching contract creation info
const etherscanApiKey = process.env.ETHERSCAN_API_KEY || null;

// Rate limiting: delay between Etherscan API calls (ms)
const API_DELAY_MS = 250;

// Chain IDs that don't support Etherscan API v2 with free API key
// Users need to manually add blockNumber to env files for these chains
const UNSUPPORTED_ETHERSCAN_CHAINS = new Set([
    56,     // BNB Smart Chain mainnet
    97,     // BNB Smart Chain testnet
    8453,   // Base mainnet
    84532,  // Base Sepolia
]);

// Chain IDs that need custom explorer APIs (not Etherscan)
const CUSTOM_EXPLORER_CHAINS = new Set([
    43114,  // Avalanche (uses Routescan)
    98866,  // Plume (uses Conduit explorer)
]);

/**
 * Sleeps for the specified number of milliseconds.
 */
function sleep(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Registry URLs for fetching current live registries
 */
const REGISTRY_URLS = {
    mainnet: "https://registry.centrifuge.io",
    testnet: "https://registry.testnet.centrifuge.io",
};

/**
 * Fetches the current live registry from the registry URL.
 * 
 * @param {string} environment - "mainnet" or "testnet"
 * @returns {Promise<Object|null>} The current live registry or null if not found
 */
async function fetchCurrentRegistry(environment) {
    const url = REGISTRY_URLS[environment];
    if (!url) {
        console.warn(`No registry URL configured for environment: ${environment}`);
        return null;
    }

    console.log(`Fetching current registry from ${url}...`);
    try {
        const response = await fetch(url);
        if (!response.ok) {
            console.warn(`Failed to fetch registry: ${response.status} ${response.statusText}`);
            return null;
        }
        const registry = await response.json();
        console.log(`  ✓ Fetched registry with version: ${registry.version || registry.deploymentInfo?.gitCommit || "unknown"}`);
        return registry;
    } catch (error) {
        console.warn(`Could not fetch current registry from ${url}: ${error.message}`);
        return null;
    }
}

/**
 * Extracts version string from deploymentInfo in env files.
 * Looks for version in deploy:protocol or other deployment entries.
 * 
 * @param {Object} chain - Chain configuration object from env/*.json
 * @returns {string|null} Version string or null if not found
 */
function getVersionFromDeploymentInfo(chain) {
    const info = chain.deploymentInfo;
    if (!info || typeof info !== "object") return null;

    // First, check deploy:protocol which is the main deployment
    if (info["deploy:protocol"]?.version) {
        return info["deploy:protocol"].version;
    }

    // Fall back to any entry with a version
    for (const value of Object.values(info)) {
        if (value?.version) {
            return value.version;
        }
    }
    return null;
}

/**
 * Compares a contract from local env with the current live registry.
 * Returns true if the contract has changed (new address, blockNumber, or is new).
 * 
 * @param {string} contractName - Name of the contract
 * @param {Object} localContract - Contract data from local env file
 * @param {Object|null} currentRegistryChain - Chain data from current live registry
 * @returns {boolean} True if contract has changed
 */
function hasContractChanged(contractName, localContract, currentRegistryChain) {
    if (!currentRegistryChain?.contracts) {
        return true; // No existing registry, everything is new
    }

    const existingContract = currentRegistryChain.contracts[contractName];
    if (!existingContract) {
        return true; // New contract
    }

    const localAddress = typeof localContract === "string" ? localContract : localContract?.address;
    const existingAddress = typeof existingContract === "string" ? existingContract : existingContract?.address;

    // Contract changed if address is different
    if (localAddress?.toLowerCase() !== existingAddress?.toLowerCase()) {
        return true;
    }

    // Also check blockNumber - if it changed, the contract was redeployed
    const localBlock = localContract?.blockNumber;
    const existingBlock = existingContract?.blockNumber;
    if (localBlock && existingBlock && String(localBlock) !== String(existingBlock)) {
        return true;
    }

    return false;
}

/**
 * Extracts deployment block range from deploymentInfo.
 * 
 * Looks for startBlock and endBlock in deploymentInfo entries.
 * 
 * @param {Object} chain - Chain configuration object from env/*.json
 * @returns {Object|null} Object with startBlock and endBlock, or null if not found
 */
function getDeploymentBlockRange(chain) {
    const info = chain.deploymentInfo;
    if (!info || typeof info !== "object") return null;

    // Scan all values in deploymentInfo for startBlock and endBlock
    for (const value of Object.values(info)) {
        if (!value || typeof value !== "object") continue;
        if (value.startBlock != null || value.endBlock != null) {
            return {
                startBlock: value.startBlock != null ? Number(value.startBlock) : null,
                endBlock: value.endBlock != null ? Number(value.endBlock) : null,
            };
        }
    }
    return null;
}

/**
 * Fetches contract creation info from Etherscan API v2.
 * 
 * @param {number} chainId - Chain ID
 * @param {string} contractAddress - Contract address
 * @returns {Promise<Object|null>} Object with blockNumber, timestamp and txHash, or null if not found
 */
async function fetchContractCreationInfo(chainId, contractAddress) {
    if (!etherscanApiKey) {
        return null;
    }

    const url = `https://api.etherscan.io/v2/api?apikey=${etherscanApiKey}&chainid=${chainId}&module=contract&action=getcontractcreation&contractaddresses=${contractAddress}`;

    try {
        const response = await fetch(url);
        const data = await response.json();

        if (data.status === "1" && data.result && data.result.length > 0) {
            const result = data.result[0];
            return {
                blockNumber: result.blockNumber || null,
                timestamp: result.timestamp || null,
                txHash: result.txHash || null,
            };
        }

        // Handle various API responses
        if (data.status === "0") {
            if (data.message === "No data found") {
                // CREATE3 contracts often don't have creation data available - this is expected
                console.log(`    ℹ Block not found on Etherscan. Probably a CREATE3 contract.`);
                return null;
            } else if (data.result?.includes("rate limit")) {
                console.warn(`    ⚠ Rate limit hit, waiting...`);
                await sleep(2000);
                return fetchContractCreationInfo(chainId, contractAddress); // Retry once
            } else {
                // Log both message and result for full error context
                const errorMsg = data.result || data.message || "Unknown error";
                console.warn(`    ⚠ Etherscan error: ${errorMsg}`);
            }
        }

        return null;
    } catch (error) {
        console.warn(`    ⚠ Fetch error: ${error.message}`);
        return null;
    }
}

/**
 * Fetches contract creation info from Avalanche via Routescan API.
 * 
 * @param {string} contractAddress - Contract address
 * @returns {Promise<Object|null>} Object with blockNumber, timestamp and txHash, or null if not found
 */
async function fetchContractCreationInfoAvalanche(contractAddress) {
    const url = `https://api.routescan.io/v2/network/mainnet/evm/43114/etherscan/api?module=contract&action=getcontractcreation&contractaddresses=${contractAddress}`;

    try {
        const response = await fetch(url);
        const data = await response.json();

        if (data.status === "1" && data.result && data.result.length > 0) {
            const txHash = data.result[0].txHash;
            if (!txHash) return null;

            // Fetch transaction details to get block number and timestamp
            const txUrl = `https://api.routescan.io/v2/network/mainnet/evm/43114/transactions/${txHash}`;
            const txResponse = await fetch(txUrl);
            const txData = await txResponse.json();

            return {
                blockNumber: txData.blockNumber ? String(txData.blockNumber) : null,
                timestamp: txData.timestamp ? String(Math.floor(new Date(txData.timestamp).valueOf() / 1000)) : null,
                txHash: txHash,
            };
        }

        return null;
    } catch (error) {
        console.warn(`    ⚠ Routescan fetch error: ${error.message}`);
        return null;
    }
}

/**
 * Fetches contract creation info from Plume via Conduit explorer API.
 * 
 * @param {string} contractAddress - Contract address
 * @returns {Promise<Object|null>} Object with blockNumber, timestamp and txHash, or null if not found
 */
async function fetchContractCreationInfoPlume(contractAddress) {
    const addressUrl = `https://explorer-plume-mainnet-1.t.conduit.xyz/api/v2/addresses/${contractAddress}`;

    try {
        const addressResponse = await fetch(addressUrl);
        const addressData = await addressResponse.json();
        const txHash = addressData.creation_transaction_hash;

        if (!txHash) return null;

        const txUrl = `https://explorer-plume-mainnet-1.t.conduit.xyz/api/v2/transactions/${txHash}`;
        const txResponse = await fetch(txUrl);
        const txData = await txResponse.json();

        return {
            blockNumber: txData.block_number ? String(txData.block_number) : null,
            timestamp: txData.timestamp ? String(Math.floor(new Date(txData.timestamp).valueOf() / 1000)) : null,
            txHash: txHash,
        };
    } catch (error) {
        console.warn(`    ⚠ Plume explorer fetch error: ${error.message}`);
        return null;
    }
}

/**
 * Processes contracts to fetch block numbers from explorers.
 * 
 * For each contract:
 * - Fetches creation info from appropriate explorer API (Etherscan, Routescan, Conduit, etc.)
 * - Sets blockNumber to the fetched value, or null if not found
 * - Skips fetching for chains not supported by free API keys (BNB, Base)
 * 
 * @param {Object} chain - Chain configuration object from env/*.json
 * @param {string} networkFile - Filename of the env file (for error messages)
 * @returns {Promise<Object>} Processed contracts with address and blockNumber (or null) for each
 */
async function processContracts(chain, networkFile) {
    const contracts = chain.contracts || {};
    const processedContracts = {};
    const chainId = chain.network.chainId;

    // Check if this chain is unsupported by free API keys
    if (UNSUPPORTED_ETHERSCAN_CHAINS.has(chainId)) {
        console.log(
            `  ⚠ Chain ${chainId} not supported by free Etherscan API. Using env file data if present.`
        );
        // Just copy contracts without fetching
        for (const [contractName, contractData] of Object.entries(contracts)) {
            const address = typeof contractData === "string"
                ? contractData
                : contractData?.address;
            const blockNumber = contractData?.blockNumber || null;
            const txHash = contractData?.txHash || null;

            const normalized = {
                address: address,
                blockNumber: blockNumber != null ? Number(blockNumber) : null,
                txHash: txHash || null,
            };
            processedContracts[contractName] = normalized;

            // Normalize env format to object shape as well, but avoid writing explicit nulls
            if (!chain.contracts) chain.contracts = {};
            const envContract = { address };
            if (normalized.blockNumber) envContract.blockNumber = normalized.blockNumber;
            if (normalized.txHash) envContract.txHash = normalized.txHash;
            chain.contracts[contractName] = envContract;
        }
        return processedContracts;
    }

    const contractEntries = Object.entries(contracts);
    const totalContracts = contractEntries.length;
    let processed = 0;

    for (const [contractName, contractData] of contractEntries) {
        processed++;

        // Extract address - could be string or object with address property
        const address = typeof contractData === "string"
            ? contractData
            : contractData?.address;

        // Check if blockNumber and txHash already exist in the env file
        let blockNumber = contractData?.blockNumber || null;
        let txHash = contractData?.txHash || null;

        if (blockNumber && txHash) {
            // Already have full creation info from env file
            console.log(
                `  [${processed}/${totalContracts}] ${contractName}: using existing metadata from env file`
            );
        } else if (CUSTOM_EXPLORER_CHAINS.has(chainId)) {
            // Use custom explorer APIs for specific chains
            let explorerName;
            let creationInfo;

            switch (chainId) {
                case 43114: // Avalanche
                    explorerName = "Routescan";
                    console.log(`  [${processed}/${totalContracts}] ${contractName}: fetching explorer metadata from ${explorerName}...`);
                    creationInfo = await fetchContractCreationInfoAvalanche(address);
                    break;
                case 98866: // Plume
                    explorerName = "Plume Explorer";
                    console.log(`  [${processed}/${totalContracts}] ${contractName}: fetching from ${explorerName}...`);
                    creationInfo = await fetchContractCreationInfoPlume(address);
                    break;
            }

            if (creationInfo?.blockNumber) {
                blockNumber = creationInfo.blockNumber;
            }
            if (creationInfo?.txHash && !txHash) {
                txHash = creationInfo.txHash;
            }

            // Rate limiting
            await sleep(API_DELAY_MS);
        } else if (etherscanApiKey) {
            // Fetch from Etherscan
            console.log(`  [${processed}/${totalContracts}] ${contractName}: fetching explorer metadata from Etherscan...`);

            const creationInfo = await fetchContractCreationInfo(chainId, address);

            if (creationInfo?.blockNumber) {
                blockNumber = creationInfo.blockNumber;
            }
            if (creationInfo?.txHash && !txHash) {
                txHash = creationInfo.txHash;
            }

            // Rate limiting
            await sleep(API_DELAY_MS);
        } else {
            console.log(`  [${processed}/${totalContracts}] ${contractName}: no API key, skipping explorer fetch`);
        }

        // Always include blockNumber and txHash fields (null if not found) in the registry
        const normalized = {
            address: address,
            blockNumber: blockNumber != null ? Number(blockNumber) : null,
            txHash: txHash || null,
        };
        processedContracts[contractName] = normalized;

        // Also update the in-memory env representation so env/*.json can be rewritten
        // but avoid writing explicit nulls to keep env files clean
        if (!chain.contracts) chain.contracts = {};
        const envContract = { address };
        if (blockNumber) envContract.blockNumber = String(blockNumber);
        if (txHash) envContract.txHash = txHash;
        chain.contracts[contractName] = envContract;
    }

    return processedContracts;
}


/**
 * Main entry point: generates a delta registry JSON file.
 * 
 * Process:
 * 1. Fetch current live registry from registry.centrifuge.io
 * 2. Process each chain in env/*.json matching the environment
 * 3. Compare contracts to detect what's changed
 * 4. Fetch contract block numbers from Etherscan for changed contracts
 * 5. Combine into delta registry structure with previousRegistry pointer
 * 6. Write to output file
 */
async function main() {
    console.log(`Generating delta registry for ${selector}...`);

    if (!etherscanApiKey) {
        console.warn("⚠ ETHERSCAN_API_KEY not set - contract block numbers will be null");
    }

    // Fetch the current live registry to compare against
    const currentRegistry = await fetchCurrentRegistry(selector);
    const currentChains = currentRegistry?.chains || {};

    // Extract previous version info for the previousRegistry pointer
    const previousVersion = currentRegistry?.version || currentRegistry?.deploymentInfo?.gitCommit || null;

    // Process all chain configurations from env/*.json files
    const networkFiles = readdirSync(join(process.cwd(), "env")).filter((file) =>
        file.endsWith(".json")
    );

    const chains = {};
    const deploymentCommits = new Set();
    const versions = new Set();
    let totalChangedContracts = 0;
    let totalContracts = 0;
    let lowestStartBlock = null;

    // Build chain registry entries for all chains matching the environment
    for (const networkFile of networkFiles) {
        const envFile = join(process.cwd(), "env", networkFile);
        const chain = JSON.parse(readFileSync(envFile, "utf8"));
        const chainId = chain.network.chainId;

        // Skip chains that don't match the selected environment
        if (chain.network.environment !== selector) continue;

        console.log(`\nProcessing chain ${chainId} (${networkFile})...`);

        // Copy chain configuration (network, adapters)
        // Filter out deployment-only fields from network and adapters
        const { environment, connectsTo, ...networkFields } = chain.network;

        const cleanedAdapters = {};
        if (chain.adapters) {
            for (const [adapterName, adapterConfig] of Object.entries(chain.adapters)) {
                const { deploy, ...adapterFields } = adapterConfig;
                cleanedAdapters[adapterName] = adapterFields;
            }
        }

        // Get the current registry chain data for comparison
        const currentRegistryChain = currentChains[chainId];

        // Process ALL contracts to normalize env file data (will skip fetches for contracts with existing data)
        const allProcessedContracts = await processContracts(chain, networkFile);

        // Identify changed contracts by comparing with current live registry
        const changedContractNames = new Set();
        const allContracts = chain.contracts || {};
        
        for (const [contractName, contractData] of Object.entries(allContracts)) {
            totalContracts++;
            if (hasContractChanged(contractName, contractData, currentRegistryChain)) {
                changedContractNames.add(contractName);
                totalChangedContracts++;
            }
        }

        console.log(`  Found ${changedContractNames.size}/${Object.keys(allContracts).length} changed contracts`);

        // Filter to only include changed contracts in the delta registry
        const processedContracts = {};
        for (const [name, data] of Object.entries(allProcessedContracts)) {
            if (changedContractNames.has(name)) {
                processedContracts[name] = data;
            }
        }

        // Only include chain if it has changed contracts
        if (Object.keys(processedContracts).length > 0) {
            chains[chainId] = {
            network: networkFields,
            adapters: cleanedAdapters,
            contracts: processedContracts,
        };

        // Extract deployment metadata (timestamp and block range) from env file
        const deployment = getDeploymentMetadata(chain, networkFile);
        chains[chainId].deployment = deployment;

            // Track lowest startBlock across all chains for registry-level startBlock
            if (deployment.startBlock && (lowestStartBlock === null || deployment.startBlock < lowestStartBlock)) {
                lowestStartBlock = deployment.startBlock;
            }
        }

        // Collect deployment commits and versions for version info
        const chainCommit = getDeploymentGitCommit(chain);
        if (chainCommit) {
            deploymentCommits.add(chainCommit);
        }
        const chainVersion = getVersionFromDeploymentInfo(chain);
        if (chainVersion) {
            versions.add(chainVersion);
        }

        // Persist any normalized contract data (blockNumber/txHash) back to env file
        try {
            writeFileSync(envFile, JSON.stringify(chain, null, 2));
        } catch (error) {
            console.warn(`  ⚠ Failed to write updated env file ${envFile}: ${error.message}`);
        }
    }

    // Determine the version for this registry
    const resolvedVersion = versions.size > 0 ? Array.from(versions)[0] : null;
    if (versions.size > 1) {
        console.warn(`⚠ Multiple versions found across chains: ${Array.from(versions).join(", ")}. Using: ${resolvedVersion}`);
    }

    // Initialize delta registry structure
    const registry = {
        network: selector,
        version: resolvedVersion,
        deploymentInfo: {
            gitCommit: resolveDeploymentCommit(deploymentCommitOverride, deploymentCommits),
            startBlock: lowestStartBlock,
        },
        // previousRegistry pointer - ipfsHash will be filled by pin-to-ipfs.js
        previousRegistry: previousVersion ? {
            version: previousVersion,
            ipfsHash: null, // Filled by pin-to-ipfs.js via Pinata query
        } : null,
        chains: chains,
    };

    // Extract ABIs only for changed contracts
    registry.abis = packAbis(chains);

    // Log summary
    console.log(`\n=== Delta Registry Summary ===`);
    console.log(`  Version: ${resolvedVersion || "unknown"}`);
    console.log(`  Previous version: ${previousVersion || "none (first registry)"}`);
    console.log(`  Changed contracts: ${totalChangedContracts}/${totalContracts}`);
    console.log(`  Chains with changes: ${Object.keys(chains).length}`);
    console.log(`  ABIs included: ${Object.keys(registry.abis).length}`);

    const outputPath = join(process.cwd(), "registry", `registry-${selector}.json`);
    const outputDir = dirname(outputPath);
    if (outputDir && !existsSync(outputDir)) {
        mkdirSync(outputDir, { recursive: true });
    }
    writeFileSync(outputPath, JSON.stringify(registry, null, 2), "utf8");
    console.log(`\nDelta registry written to ${outputPath}`);
}

/**
 * Extracts deployment metadata from chain.deploymentInfo in env files.
 * 
 * @param {Object} chain - Chain configuration object from env/*.json
 * @returns {Object|null} Deployment metadata with deployedAt and block range
 */
function getDeploymentInfoFromEnv(chain) {
    const info = chain.deploymentInfo;
    if (!info || typeof info !== "object") return null;

    // Scan all values in deploymentInfo (supports nested structures)
    for (const value of Object.values(info)) {
        if (!value || typeof value !== "object") continue;

        // Extract and normalize timestamp
        const deployedAt = normalizeTimestamp(
            value.timestamp ?? value.deployedAt
        );
        if (!deployedAt) continue;

        return {
            deployedAt,
        };
    }
    return null;
}


/**
 * Normalizes a timestamp to Unix seconds (number).
 * 
 * @param {string|number|null} rawTimestamp - Raw timestamp value
 * @returns {number|null} Unix timestamp in seconds as a number, or null if invalid
 */
function normalizeTimestamp(rawTimestamp) {
    if (rawTimestamp == null) return null;
    const tsString = String(rawTimestamp);

    // If already a numeric string (Unix timestamp), return as number
    if (/^\d+$/.test(tsString)) {
        return Number(tsString);
    }

    // Try parsing as ISO date string
    const parsed = new Date(tsString);
    if (Number.isNaN(parsed.valueOf())) {
        return null;
    }

    // Convert to Unix seconds
    return Math.floor(parsed.valueOf() / 1000);
}

/**
 * Resolves the deployment commit hash for the registry version field.
 * 
 * @param {string|null} override - DEPLOYMENT_COMMIT env var value
 * @param {Set<string>} commitsSet - Set of git commits found in chain deploymentInfo
 * @returns {string} Git commit hash to use in registry.deploymentInfo.gitCommit
 */
function resolveDeploymentCommit(override, commitsSet) {
    if (override) {
        return override;
    }

    if (commitsSet.size === 0) {
        throw new Error(
            `No deploymentInfo.gitCommit found for environment "${selector}".`
        );
    }
    if (commitsSet.size > 1) {
        const firstCommit = commitsSet.values().next().value;
        console.warn(
            `Multiple deploymentInfo.gitCommit values found for environment "${selector}": ${Array.from(
                commitsSet
            ).join(", ")}. Using first: ${firstCommit}`
        );
        return firstCommit;
    }
    return commitsSet.values().next().value;
}

/**
 * Extracts git commit hash from chain.deploymentInfo.
 * 
 * @param {Object} chain - Chain configuration object from env/*.json
 * @returns {string|null} Git commit hash or null if not found
 */
function getDeploymentGitCommit(chain) {
    const info = chain.deploymentInfo;
    if (!info || typeof info !== "object") return null;
    for (const value of Object.values(info)) {
        if (value?.gitCommit) {
            return value.gitCommit;
        }
    }
    return null;
}

/**
 * Extracts ABIs from Forge build artifacts in ./out/ directory.
 * Only includes ABIs for contracts that are actually deployed (based on env file contracts).
 * 
 * @param {Object} chains - The chains object with deployed contracts
 * @returns {Object} Map of contract names to their ABIs
 * @throws {Error} If ./out/ directory doesn't exist
 */
function packAbis(chains) {
    const outputDir = join(process.cwd(), "out");

    if (!existsSync(outputDir)) {
        throw new Error(
            "Forge build artifacts not found in ./out. Run `forge build --skip test` for the deployment commit before generating the registry."
        );
    }

    // Collect all unique contract names from deployed contracts across chains
    // Capitalize first letter to match ABI filename (e.g., "hub" → "Hub")
    // Also include base contracts for factories (e.g., PoolEscrowFactory → PoolEscrow)
    const deployedContracts = new Set();

    for (const chain of Object.values(chains)) {
        const contracts = Object.keys(chain.contracts || {});
        for (const name of contracts) {
            const capitalized = name.charAt(0).toUpperCase() + name.slice(1);
            deployedContracts.add(capitalized);

            // If this is a factory, also include the underlying implementation ABI
            if (capitalized.endsWith("Factory")) {
                const baseName = capitalized.replace(/Factory$/, "");
                deployedContracts.add(baseName);
            }
        }
    }

    const abis = {};
    const abiDirs = readdirSync(outputDir);
    for (const abiDir of abiDirs) {
        // Skip test files
        if (abiDir.endsWith(".t.sol")) continue;

        const files = readdirSync(join(outputDir, abiDir));
        for (const file of files) {
            if (!file.endsWith(".json")) continue;

            const contractName = file.replace(".json", "");
            if (!deployedContracts.has(contractName)) continue;

            const contractData = JSON.parse(
                readFileSync(join(outputDir, abiDir, file), "utf8")
            );
            abis[contractName] = contractData.abi;
        }
    }

    console.log(`Packed ${Object.keys(abis).length} ABIs for deployed contracts`);
    return abis;
}

main()
    .catch((error) => {
        console.error(error);
        process.exit(1);
    })
    .then(() => {
        console.log("Registry built successfully");
        process.exit(0);
    });

/**
 * Extracts deployment metadata from deploymentInfo in env files.
 * 
 * Returns:
 * - deployedAt: timestamp of deployment
 * - startBlock: block before deployment started (for indexing)
 * - endBlock: block after deployment finished (for indexing)
 * 
 * @param {Object} chain - Chain configuration object from env/*.json
 * @param {string} networkFile - Filename of the env file
 * @returns {Object} Deployment metadata
 */
function getDeploymentMetadata(chain, networkFile) {
    const fromEnv = getDeploymentInfoFromEnv(chain);
    const blockRange = getDeploymentBlockRange(chain);
    const chainId = chain.network.chainId;

    const timestamp = fromEnv?.deployedAt || null;
    const startBlock = blockRange?.startBlock || null;
    const endBlock = blockRange?.endBlock || null;

    if (!timestamp && !startBlock && !endBlock) {
        console.warn(
            `  ⚠ Chain ${chainId} (env/${networkFile}) is missing deploymentInfo`
        );
    }

    return {
        deployedAt: timestamp,
        startBlock: startBlock,
        endBlock: endBlock,
    };
}
