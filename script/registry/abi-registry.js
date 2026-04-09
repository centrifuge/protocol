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
 * 5. Extracts ABIs from per-tag Forge caches (git tag per env contract `version`)
 * 6. Combines into a delta registry with previousRegistry pointer
 *
 * Usage:
 *   # Delta mode (default):
 *   DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> node script/registry/abi-registry.js [mainnet|testnet]
 *
 *   # Full snapshot mode (rebuild from scratch):
 *   DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> node script/registry/abi-registry.js [mainnet|testnet] --full
 *
 *   # Delta mode with IPFS hash (regenerate against specific previous registry):
 *   DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> SOURCE_IPFS=Qm... node script/registry/abi-registry.js [mainnet|testnet]
 *
 * Environment Variables:
 *   - DEPLOYMENT_COMMIT: Git commit hash used to build the ABIs (required in CI)
 *   - ETHERSCAN_API_KEY: API key for Etherscan v2 API (required for block number fetching)
 *   - REGISTRY_MODE: Set to "full" to generate a full snapshot (alternative to --full flag)
 *   - SOURCE_IPFS: IPFS hash (CID) of previous registry to compare against (Qm... or bafy...)
 *
 * CLI Arguments:
 *   - --full: Generate a full snapshot registry (includes all contracts, no delta comparison)
 *
 * Output files:
 *   - mainnet: registry/registry-mainnet.json
 *   - testnet: registry/registry-testnet.json
 *
 * Output: A JSON file with structure:
 *   {
 *     network: "mainnet" | "testnet",
 *     version: "3.1",  // optional; omitted if unknown
 *     deploymentInfo: { gitCommit: "...", startBlock: ... },
 *     previousRegistry: { version: "3.0", ipfsHash: "Qm..." }, // ipfsHash from SOURCE_IPFS if provided, otherwise filled by pin-to-ipfs.js
 *     abis: { ContractName: [...], ... },
 *     chains: { chainId: { network, adapters, contracts, deployment }, ... }
 *   }
 *
 * Note: The previousRegistry.ipfsHash is set from SOURCE_IPFS if provided.
 * Otherwise, it's resolved via DNS dnslink lookup on the live registry hostname
 * (e.g. _dnslink.registry.centrifuge.io → dnslink=/ipfs/<CID>).
 */

import {
    readFileSync,
    writeFileSync,
    readdirSync,
    mkdirSync,
    existsSync,
} from "fs";
import { dirname, join } from "path";
import { resolveTxt } from "dns/promises";
import {
    collectContractTags,
    ensureAbiCache,
    findAbiInOutput,
    getAbiCacheRoot,
    getCachedOutDir,
    resolveArtifactName,
} from "./utils/abi-cache.js";

// Parse CLI arguments
const args = process.argv.slice(2);
let selector = "mainnet";
let fullMode = false;

// Parse arguments: [mainnet|testnet] [--full]
for (const arg of args) {
    if (arg === "mainnet" || arg === "testnet") {
        selector = arg;
    } else if (arg === "--full") {
        fullMode = true;
    }
}

// Check for REGISTRY_MODE env var (overrides --full flag)
if (process.env.REGISTRY_MODE === "full") {
    fullMode = true;
}

// Get SOURCE_IPFS from environment
const sourceIpfs = process.env.SOURCE_IPFS || null;

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
 * IPFS gateway URL (Pinata is used since that's where registries are pinned)
 */
const IPFS_GATEWAY = "https://gateway.pinata.cloud";

/**
 * DNS hostnames for dnslink CID resolution.
 * Cloudflare Web3 hostnames publish a TXT record at _dnslink.<hostname>
 * with value "dnslink=/ipfs/<CID>".
 */
const DNSLINK_HOSTNAMES = {
    mainnet: "registry.centrifuge.io",
    testnet: "registry.testnet.centrifuge.io",
};

/**
 * Resolves the IPFS CID of the currently live registry via DNS TXT lookup.
 * This is the source of truth — the dnslink record points to whatever CID
 * Cloudflare is actually serving.
 *
 * @param {string} environment - "mainnet" or "testnet"
 * @returns {Promise<string|null>} IPFS CID or null if not resolvable
 */
async function resolveLiveCid(environment) {
    const hostname = DNSLINK_HOSTNAMES[environment];
    if (!hostname) return null;

    const dnslinkHost = `_dnslink.${hostname}`;
    try {
        console.log(`  Resolving live CID via DNS: ${dnslinkHost}`);
        const records = await resolveTxt(dnslinkHost);
        // records is an array of arrays of strings, e.g. [["dnslink=/ipfs/Qm..."]]
        for (const record of records) {
            const txt = record.join("");
            const match = txt.match(/^dnslink=\/ipfs\/(.+)$/);
            if (match) {
                const cid = match[1];
                console.log(`  ✓ Resolved live CID: ${cid}`);
                return cid;
            }
        }
        console.warn(`  ⚠ No dnslink record found at ${dnslinkHost}`);
        return null;
    } catch (error) {
        console.warn(`  ⚠ DNS lookup failed for ${dnslinkHost}: ${error.message}`);
        return null;
    }
}

/**
 * Validates that a string is a valid IPFS hash (CID).
 * Supports both v0 (Qm...) and v1 (baf...) CIDs.
 *
 * @param {string} input - String to validate
 * @returns {boolean} True if input is a valid IPFS CID
 */
function isValidIpfsHash(input) {
    if (!input || typeof input !== "string") return false;

    // Check for CID patterns:
    // v0: Qm followed by 44 base58 characters (total 46 chars)
    //     Base58 alphabet: 1-9, A-H, J-N, P-Z, a-k, m-z (excludes 0, O, I, l)
    // v1: baf followed by base32/base58 characters (variable length, typically 50+ chars)
    //     Base32 alphabet: a-z, 2-7 (lowercase only)
    //     Base58 alphabet: 1-9, A-H, J-N, P-Z, a-k, m-z (excludes 0, O, I, l)
    // For v1, we allow alphanumeric characters (more permissive to handle various encodings)
    const base58Char = "[1-9A-HJ-NP-Za-km-z]";
    const cidV0Pattern = new RegExp(`^Qm${base58Char}{44}$`);
    // v1 CIDs: baf followed by at least 50 alphanumeric characters
    // Using [a-z0-9] for base32 (most common) but allowing flexibility
    const cidV1Pattern = /^baf[a-z0-9]{50,}$/i;

    return cidV0Pattern.test(input) || cidV1Pattern.test(input);
}

/**
 * Fetches the current live registry from the registry URL or IPFS.
 *
 * @param {string} environment - "mainnet" or "testnet"
 * @param {string|null} ipfsHash - Optional IPFS hash (CID) to fetch from IPFS gateway
 * @returns {Promise<Object|null>} The current live registry or null if not found
 */
async function fetchCurrentRegistry(environment, ipfsHash = null) {
    let url;
    if (ipfsHash) {
        url = `${IPFS_GATEWAY}/ipfs/${ipfsHash}`;
        console.log(`Fetching registry from IPFS hash: ${ipfsHash} (via ${url})...`);
    } else {
        url = REGISTRY_URLS[environment];
        if (!url) {
            console.warn(`No registry URL configured for environment: ${environment}`);
            return null;
        }
        console.log(`Fetching current registry from ${url}...`);
    }

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
 * Normalizes a version string for comparison.
 * Strips leading "v" and splits into numeric segments.
 * e.g. "v3.1" → [3, 1], "3" → [3]
 */
function parseVersion(v) {
    return v.replace(/^v/i, "").split(".").map(Number);
}

/**
 * Compares two version strings. Returns > 0 if a > b, < 0 if a < b, 0 if equal.
 */
function compareVersions(a, b) {
    const pa = parseVersion(a);
    const pb = parseVersion(b);
    const len = Math.max(pa.length, pb.length);
    for (let i = 0; i < len; i++) {
        const diff = (pa[i] || 0) - (pb[i] || 0);
        if (diff !== 0) return diff;
    }
    return 0;
}

/**
 * Extracts the highest version string from an env file.
 * Checks deploymentInfo first, then collects all contract-level versions
 * and returns the highest one (e.g. "v3.1" wins over "3").
 *
 * @param {Object} chain - Chain configuration object from env/*.json
 * @returns {string|null} Version string or null if not found
 */
function getVersionFromChain(chain) {
    const info = chain.deploymentInfo;
    if (info && typeof info === "object") {
        if (info["deploy:protocol"]?.version) {
            return info["deploy:protocol"].version;
        }
        for (const value of Object.values(info)) {
            if (value?.version) {
                return value.version;
            }
        }
    }

    const contracts = chain.contracts;
    if (contracts && typeof contracts === "object") {
        let highest = null;
        for (const value of Object.values(contracts)) {
            const v = value?.version;
            if (v && (!highest || compareVersions(v, highest) > 0)) {
                highest = v;
            }
        }
        return highest;
    }

    return null;
}

/**
 * Parses env-style protocol labels ("3", "v3.1", "v3.1.0") for ordering.
 * @param {string} s
 * @returns {[number, number, number]}
 */
function protocolVersionTuple(s) {
    const n = String(s)
        .replace(/^v/i, "")
        .trim()
        .split("-")[0];
    const parts = n.split(".").map((p) => parseInt(p, 10));
    return [
        Number.isFinite(parts[0]) ? parts[0] : 0,
        Number.isFinite(parts[1]) ? parts[1] : 0,
        Number.isFinite(parts[2]) ? parts[2] : 0,
    ];
}

/**
 * @param {string} a
 * @param {string} b
 * @returns {number}
 */
function compareProtocolVersionStrings(a, b) {
    const ta = protocolVersionTuple(a);
    const tb = protocolVersionTuple(b);
    for (let i = 0; i < 3; i++) {
        if (ta[i] !== tb[i]) return ta[i] - tb[i];
    }
    return 0;
}

/**
 * Highest label by numeric major.minor.patch (for mixed "3" vs "v3.1" in env).
 * @param {string[]} strings
 * @returns {string|null}
 */
function maxProtocolVersionLabel(strings) {
    const uniq = [...new Set(strings.filter((s) => s && typeof s === "string"))];
    if (uniq.length === 0) return null;
    uniq.sort(compareProtocolVersionStrings);
    return uniq[uniq.length - 1] ?? null;
}

/**
 * Canonical top-level registry.version for JSON output: always vX.Y.Z (patch explicit).
 *
 * @param {string} label - Raw env or deployment label (e.g. "3", "v3.1")
 * @returns {string|null}
 */
function normalizeRegistryVersionToVSemver(label) {
    if (!label || typeof label !== "string") return null;
    const [major, minor, patch] = protocolVersionTuple(label);
    return `v${major}.${minor}.${patch}`;
}

/**
 * Max of per-contract `version` across chains (skips deprecated tombstones).
 * Used when deploymentInfo has no protocol version — api-v3 `update-registry` expects top-level version.
 *
 * @param {Object} chains - registry.chains-shaped object before stripContractVersionsForRegistryOutput
 * @returns {string|null}
 */
function deriveHighestContractVersion(chains) {
    const labels = [];
    for (const chain of Object.values(chains)) {
        const contracts = chain?.contracts;
        if (!contracts || typeof contracts !== "object") continue;
        for (const data of Object.values(contracts)) {
            if (!data || typeof data !== "object" || data.address === null) continue;
            if (data.version && typeof data.version === "string") labels.push(data.version);
        }
    }
    return maxProtocolVersionLabel(labels);
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
 * Extracts deployment startBlock from deploymentInfo.
 *
 * Looks for startBlock in deploymentInfo entries.
 *
 * @param {Object} chain - Chain configuration object from env/*.json
 * @returns {number|null} startBlock or null if not found
 */
function getDeploymentStartBlock(chain) {
    const info = chain.deploymentInfo;
    if (!info || typeof info !== "object") return null;

    // Scan all values in deploymentInfo for startBlock
    for (const value of Object.values(info)) {
        if (!value || typeof value !== "object") continue;
        if (value.startBlock != null) {
            return Number(value.startBlock);
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
 * @returns {Promise<{contracts: Object, hasChanges: boolean}>} Processed contracts and whether any data was fetched
 */
async function processContracts(chain, networkFile) {
    const contracts = chain.contracts || {};
    const processedContracts = {};
    const chainId = chain.network.chainId;
    let hasChanges = false;

    // Check if this chain is unsupported by free API keys
    if (UNSUPPORTED_ETHERSCAN_CHAINS.has(chainId)) {
        console.log(
            `  ⚠ Chain ${chainId} not supported by free Etherscan API. Using env file data if present.`
        );
        // Just copy contracts without fetching (no changes to env file needed)
        for (const [contractName, contractData] of Object.entries(contracts)) {
            const address = typeof contractData === "string"
                ? contractData
                : contractData?.address;
            const blockNumber = contractData?.blockNumber || null;
            const txHash = contractData?.txHash || null;
            const version = contractData?.version || null;

            processedContracts[contractName] = {
                address: address,
                blockNumber: blockNumber != null ? Number(blockNumber) : null,
                txHash: txHash || null,
                ...(version && { version }),
            };
        }
        return { contracts: processedContracts, hasChanges: false };
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
        let fetchedNewData = false;

        if (blockNumber && txHash) {
            // Already have full creation info from env file - skip fetching
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

            if (creationInfo?.blockNumber && !blockNumber) {
                blockNumber = creationInfo.blockNumber;
                fetchedNewData = true;
            }
            if (creationInfo?.txHash && !txHash) {
                txHash = creationInfo.txHash;
                fetchedNewData = true;
            }

            // Rate limiting
            await sleep(API_DELAY_MS);
        } else if (etherscanApiKey) {
            // Fetch from Etherscan
            console.log(`  [${processed}/${totalContracts}] ${contractName}: fetching explorer metadata from Etherscan...`);

            const creationInfo = await fetchContractCreationInfo(chainId, address);

            if (creationInfo?.blockNumber && !blockNumber) {
                blockNumber = creationInfo.blockNumber;
                fetchedNewData = true;
            }
            if (creationInfo?.txHash && !txHash) {
                txHash = creationInfo.txHash;
                fetchedNewData = true;
            }

            // Rate limiting
            await sleep(API_DELAY_MS);
        } else {
            console.log(`  [${processed}/${totalContracts}] ${contractName}: no API key, skipping explorer fetch`);
        }

        // Always include blockNumber and txHash fields (null if not found) in the registry
        const version = contractData?.version || null;
        processedContracts[contractName] = {
            address: address,
            blockNumber: blockNumber != null ? Number(blockNumber) : null,
            txHash: txHash || null,
            ...(version && { version }),
        };

        // Update env file data if we fetched new metadata
        if (fetchedNewData) {
            hasChanges = true;
            if (!chain.contracts) chain.contracts = {};
            const envContract = { address };
            if (blockNumber) envContract.blockNumber = Number(blockNumber);
            if (txHash) envContract.txHash = txHash;
            // Preserve version (and any future env-only fields) — required for ABI tag resolution / CI
            if (typeof contractData === "object" && contractData?.version) {
                envContract.version = contractData.version;
            }
            chain.contracts[contractName] = envContract;
        }
    }

    return { contracts: processedContracts, hasChanges };
}


/**
 * Main entry point: generates a delta registry JSON file.
 *
 * Process:
 * 1. Fetch current live registry from registry.centrifuge.io (unless in full mode)
 * 2. Process each chain in env/*.json matching the environment
 * 3. Compare contracts to detect what's changed (unless in full mode)
 * 4. Fetch contract block numbers from Etherscan for changed contracts
 * 5. Combine into delta registry structure with previousRegistry pointer
 * 6. Write to output file
 */
async function main() {
    if (fullMode) {
        console.log(`Generating FULL registry snapshot for ${selector}...`);
        console.log(`  Mode: Full snapshot (all contracts included, no delta comparison)`);
    } else {
        console.log(`Generating delta registry for ${selector}...`);
        if (sourceIpfs) {
            console.log(`  Using SOURCE_IPFS: ${sourceIpfs}`);
        }
    }

    // Validate SOURCE_IPFS if provided
    if (sourceIpfs && !isValidIpfsHash(sourceIpfs)) {
        console.error(`Error: SOURCE_IPFS must be a valid IPFS hash (CID). Got: ${sourceIpfs}`);
        console.error(`Expected format: Qm... (v0) or bafy... (v1)`);
        process.exit(1);
    }

    if (!etherscanApiKey) {
        console.warn("⚠ ETHERSCAN_API_KEY not set - contract block numbers will be null");
    }

    // Fetch the current live registry to compare against (skip in full mode)
    let currentRegistry = null;
    let currentChains = {};
    let previousVersion = null;
    let previousIpfsHash = sourceIpfs; // Use SOURCE_IPFS if provided

    if (!fullMode) {
        if (sourceIpfs) {
            console.log(`  Using IPFS hash for previousRegistry: ${sourceIpfs}`);
        }

        currentRegistry = await fetchCurrentRegistry(selector, sourceIpfs);
        currentChains = currentRegistry?.chains || {};
        previousVersion = currentRegistry?.version || currentRegistry?.deploymentInfo?.gitCommit || null;

        if (sourceIpfs && currentRegistry) {
            console.log(`  Comparing against registry version: ${previousVersion || "unknown"}`);
        } else if (!sourceIpfs && !currentRegistry) {
            console.warn(`  ⚠ Could not fetch current registry for comparison`);
        }

        // Resolve the live CID via DNS if not explicitly provided
        if (!previousIpfsHash && previousVersion) {
            previousIpfsHash = await resolveLiveCid(selector);
        }
    } else {
        console.log(`  Skipping registry fetch (full mode - no comparison)`);
        // In full mode, set previousRegistry to null to mark this as the base registry
        previousVersion = null;
    }

    // Process all chain configurations from env/*.json files
    const networkFiles = readdirSync(join(process.cwd(), "env")).filter((file) =>
        file.endsWith(".json")
    );

    const chains = {};
    const deploymentCommits = new Set();
    const versions = new Set();
    let totalChangedContracts = 0;
    let totalDeprecatedContracts = 0;
    let totalContracts = 0;

    // Collect original chainSelector values from all env files (to restore after JSON.stringify)
    // Map of chainId -> original chainSelector string value
    const originalChainSelectors = new Map();

    // Build chain registry entries for all chains matching the environment
    for (const networkFile of networkFiles) {
        const envFile = join(process.cwd(), "env", networkFile);
        const originalContent = readFileSync(envFile, "utf8");
        const chain = JSON.parse(originalContent);
        const chainId = chain.network.chainId;

        // Skip chains that don't match the selected environment
        if (chain.network.environment !== selector) continue;

        // Skip local development chains (Anvil/Hardhat)
        if (chainId === 31337) {
            console.log(`\nSkipping local dev chain ${chainId} (${networkFile})...`);
            continue;
        }

        console.log(`\nProcessing chain ${chainId} (${networkFile})...`);

        // Extract original chainSelector value before it gets corrupted by JSON.parse
        // chainSelector is only used by the chainlink adapter
        const chainSelectorMatch = originalContent.match(/"chainSelector":\s*(\d+)/);
        if (chainSelectorMatch) {
            originalChainSelectors.set(chainId, chainSelectorMatch[1]);
        }

        // Copy chain configuration (network, adapters)
        // Filter out deployment-only fields from network and adapters
        const { environment, ...networkFields } = chain.network;

        const cleanedAdapters = {};
        if (chain.adapters) {
            for (const [adapterName, adapterConfig] of Object.entries(chain.adapters)) {
                const { deploy, ...adapterFields } = adapterConfig;
                cleanedAdapters[adapterName] = adapterFields;
            }
        }

        // Get the current registry chain data for comparison (null in full mode)
        const currentRegistryChain = fullMode ? null : currentChains[chainId];

        // Process ALL contracts to normalize env file data (will skip fetches for contracts with existing data)
        const { contracts: allProcessedContracts, hasChanges: envFileModified } = await processContracts(chain, networkFile);

        // In full mode, include ALL contracts. In delta mode, only include changed contracts.
        let processedContracts = {};
        if (fullMode) {
            // Full mode: include all contracts
            processedContracts = allProcessedContracts;
            totalContracts += Object.keys(allProcessedContracts).length;
            totalChangedContracts += Object.keys(allProcessedContracts).length;
            console.log(`  Including all ${Object.keys(allProcessedContracts).length} contracts (full mode)`);
        } else {
            // Delta mode: identify changed contracts by comparing with current live registry
            const changedContractNames = new Set();
            const allContracts = chain.contracts || {};

            for (const [contractName, contractData] of Object.entries(allContracts)) {
                totalContracts++;
                if (hasContractChanged(contractName, contractData, currentRegistryChain)) {
                    changedContractNames.add(contractName);
                    totalChangedContracts++;
                }
            }

            // Detect deprecated contracts: present in live registry but removed from local env
            let chainDeprecated = 0;
            if (currentRegistryChain?.contracts) {
                for (const contractName of Object.keys(currentRegistryChain.contracts)) {
                    const live = currentRegistryChain.contracts[contractName];
                    // Skip keys already deprecated in the published delta (address null) — do not re-emit every run
                    if (live?.address === null) continue;
                    if (!allContracts[contractName]) {
                        processedContracts[contractName] = {
                            address: null,
                            blockNumber: null,
                            txHash: null,
                        };
                        chainDeprecated++;
                        totalDeprecatedContracts++;
                        console.log(`    ⊘ ${contractName}: deprecated (removed from env)`);
                    }
                }
            }

            console.log(`  Found ${changedContractNames.size}/${Object.keys(allContracts).length} changed contracts` +
                (chainDeprecated > 0 ? `, ${chainDeprecated} deprecated` : ""));

            // Filter to only include changed contracts in the delta registry
            for (const [name, data] of Object.entries(allProcessedContracts)) {
                if (changedContractNames.has(name)) {
                    processedContracts[name] = data;
                }
            }
        }

        // Include chain if it has contracts (all in full mode, or changed in delta mode)
        if (Object.keys(processedContracts).length > 0) {
            chains[chainId] = {
                network: networkFields,
                adapters: cleanedAdapters,
                contracts: processedContracts,
            };

            // Extract deployment metadata (timestamp and block range) from env file
            const deployment = getDeploymentMetadata(chain, networkFile);
            chains[chainId].deployment = deployment;
        }

        // Collect deployment commits and versions for version info
        const chainCommit = getDeploymentGitCommit(chain);
        if (chainCommit) {
            deploymentCommits.add(chainCommit);
        }
        const chainVersion = getVersionFromChain(chain);
        if (chainVersion) {
            versions.add(chainVersion);
        }

        // Only write env file if we fetched new data from explorers
        if (envFileModified) {
            try {
                let newContent = JSON.stringify(chain, null, 2);

                // Restore chainSelector from original (gets corrupted by JSON.parse due to exceeding MAX_SAFE_INTEGER)
                const chainSelectorMatch = originalContent.match(/"chainSelector":\s*(\d+)/);
                if (chainSelectorMatch) {
                    newContent = newContent.replace(/"chainSelector":\s*\d+/, `"chainSelector": ${chainSelectorMatch[1]}`);
                }

                writeFileSync(envFile, newContent);
                console.log(`  ✓ Updated env file with fetched metadata`);
            } catch (error) {
                console.warn(`  ⚠ Failed to write updated env file ${envFile}: ${error.message}`);
            }
        }
    }

    // Top-level version: max of deploymentInfo labels and per-contract versions (indexer codegen expects it).
    const fromDeploy = maxProtocolVersionLabel(Array.from(versions));
    if (versions.size > 1) {
        console.warn(
            `⚠ Multiple deploymentInfo versions across chains: ${Array.from(versions).join(", ")}. Using highest: ${fromDeploy}`
        );
    }
    const fromContracts = deriveHighestContractVersion(chains);
    const resolvedVersionRaw = maxProtocolVersionLabel(
        [fromDeploy, fromContracts].filter((x) => x != null)
    );
    const resolvedVersion = resolvedVersionRaw
        ? normalizeRegistryVersionToVSemver(resolvedVersionRaw)
        : null;
    if (resolvedVersion && !fromDeploy && fromContracts) {
        console.log(
            `  Registry version from per-contract env versions: ${resolvedVersionRaw} → ${resolvedVersion} (normalized vX.Y.Z)`
        );
    } else if (resolvedVersionRaw && resolvedVersion && resolvedVersionRaw !== resolvedVersion) {
        console.log(`  Normalized registry version: ${resolvedVersionRaw} → ${resolvedVersion}`);
    }

    // Initialize registry structure (top-level version is optional — omit when unknown)
    const registry = {
        network: selector,
        ...(resolvedVersion ? { version: resolvedVersion } : {}),
        deploymentInfo: {
            gitCommit: resolveDeploymentCommit(deploymentCommitOverride, deploymentCommits),
        },
        // previousRegistry pointer - ipfsHash resolved from SOURCE_IPFS env var,
        // or via DNS dnslink lookup on the live registry hostname.
        // In full mode, set to null to mark this as the base registry.
        previousRegistry: previousVersion ? {
            version: previousVersion,
            ipfsHash: previousIpfsHash || null,
        } : null,
        chains: chains,
    };

    // Extract ABIs from per-tag caches (builds from contract version tags)
    registry.abis = packAbis(chains);
    stripContractVersionsForRegistryOutput(chains);

    // Log summary
    if (fullMode) {
        console.log(`\n=== Full Registry Summary ===`);
        console.log(`  Version: ${resolvedVersion || "unknown"}`);
        console.log(`  Previous version: none (base registry)`);
        console.log(`  Total contracts: ${totalContracts}`);
        console.log(`  Chains included: ${Object.keys(chains).length}`);
        console.log(`  ABIs included: ${Object.keys(registry.abis).length}`);
    } else {
        console.log(`\n=== Delta Registry Summary ===`);
        console.log(`  Version: ${resolvedVersion || "unknown"}`);
        console.log(`  Previous version: ${previousVersion || "none (first registry)"}`);
        console.log(`  Changed contracts: ${totalChangedContracts}/${totalContracts}` +
            (totalDeprecatedContracts > 0 ? ` (${totalDeprecatedContracts} deprecated)` : ""));
        console.log(`  Chains with changes: ${Object.keys(chains).length}`);
        console.log(`  ABIs included: ${Object.keys(registry.abis).length}`);
    }

    const outputPath = join(process.cwd(), "registry", `registry-${selector}.json`);
    const outputDir = dirname(outputPath);
    if (outputDir && !existsSync(outputDir)) {
        mkdirSync(outputDir, { recursive: true });
    }

    // Stringify registry and restore chainSelector values (corrupted by JSON.parse exceeding MAX_SAFE_INTEGER)
    let registryContent = JSON.stringify(registry, null, 2);
    for (const [chainId, originalValue] of originalChainSelectors) {
        const pattern = new RegExp(`("${chainId}"[^]*?"chainSelector":\\s*)\\d+`);
        registryContent = registryContent.replace(pattern, `$1${originalValue}`);
    }

    writeFileSync(outputPath, registryContent, "utf8");
    if (fullMode) {
        console.log(`\nFull registry written to ${outputPath}`);
    } else {
        console.log(`\nDelta registry written to ${outputPath}`);
    }
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

// Env contract keys whose capitalized form doesn't match the Forge artifact name.
// Maps capitalized env key → actual Solidity contract name in out/.
const ABI_NAME_OVERRIDES = {
    "NavManager": "NAVManager",
    "FreezeOnlyHook": "FreezeOnly",
    "FullRestrictionsHook": "FullRestrictions",
    "FreelyTransferableHook": "FreelyTransferable",
    "RedemptionRestrictionsHook": "RedemptionRestrictions",
};

// Factory base name overrides: when stripping "Factory" suffix produces a name
// that doesn't match the actual artifact (e.g. TokenFactory → ShareToken, not Token).
const FACTORY_BASE_OVERRIDES = {
    "TokenFactory": "ShareToken",
};

/**
 * Drops per-contract `version` from chains before JSON output.
 * `version` is only needed during generation (env → git tag → ABI pack); omitting it keeps published registries smaller for indexers.
 *
 * @param {Object} chains - Same object later assigned to registry.chains (mutated in place)
 */
function stripContractVersionsForRegistryOutput(chains) {
    for (const chain of Object.values(chains)) {
        const contracts = chain?.contracts;
        if (!contracts || typeof contracts !== "object") continue;
        for (const data of Object.values(contracts)) {
            if (data && typeof data === "object" && Object.prototype.hasOwnProperty.call(data, "version")) {
                delete data.version;
            }
        }
    }
}

/**
 * Extracts ABIs from per-tag ABI caches for deployed contracts.
 *
 * Each contract is mapped to a git tag via its "version" field in the env file.
 * The ABI cache is built per tag using git worktrees and forge build.
 *
 * @param {Object} chains - The chains object with deployed contracts
 * @returns {Object} Map of contract names to their ABIs
 * @throws {Error} If version tags are missing or ABI cannot be found
 */
function packAbis(chains) {
    const cwd = process.cwd();
    const cacheOpts = { cwd };

    const contractToTag = collectContractTags(chains);
    const uniqueTags = new Set(contractToTag.values());

    console.log(`\nResolving ABIs for ${contractToTag.size} contracts across ${uniqueTags.size} version tag(s): ${[...uniqueTags].join(", ")}`);
    console.log(`  ABI cache root: ${getAbiCacheRoot(cwd)}`);

    for (const tag of uniqueTags) {
        ensureAbiCache(tag, cacheOpts);
    }

    const abis = {};
    const missing = [];

    for (const [contractName, tag] of contractToTag) {
        const cacheOut = getCachedOutDir(tag, cwd);
        const artifactName = resolveArtifactName(contractName);
        const abi = findAbiInOutput(cacheOut, artifactName);
        if (abi) {
            abis[artifactName] = abi;
        } else {
            missing.push(`${contractName} (artifact: ${artifactName}, tag: ${tag})`);
        }
    }

    if (missing.length > 0) {
        console.warn(`⚠ ABIs not found for: ${missing.join(", ")}`);
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
 *
 * @param {Object} chain - Chain configuration object from env/*.json
 * @param {string} networkFile - Filename of the env file
 * @returns {Object} Deployment metadata
 */
function getDeploymentMetadata(chain, networkFile) {
    const fromEnv = getDeploymentInfoFromEnv(chain);
    const startBlock = getDeploymentStartBlock(chain);
    const chainId = chain.network.chainId;

    const timestamp = fromEnv?.deployedAt || null;

    if (!timestamp && !startBlock) {
        console.warn(
            `  ⚠ Chain ${chainId} (env/${networkFile}) is missing deploymentInfo`
        );
    }

    return {
        deployedAt: timestamp,
        startBlock: startBlock,
    };
}
