#!/usr/bin/env node
/**
 * @fileoverview Generates a delta contract registry JSON file containing ABIs and chain deployment metadata.
 *
 * This script generates "delta registries" - registries that only contain contracts that have
 * changed since the previous version. Each delta registry includes a pointer to the previous
 * registry's IPFS hash, allowing indexers to walk backwards through the version chain.
 *
 * This script:
 * 1. Fetches the current live registry from registry.centrifuge.io and walks its
 *    `previousRegistry.ipfsHash` chain, merging every layer into the accumulated state an indexer
 *    would hold — that accumulated state, not the tip document, is what the delta compares against
 * 2. Reads chain configurations from env/*.json files
 * 3. Compares contracts to detect changes (new or modified addresses/blockNumbers)
 * 4. Fetches contract creation block numbers from Etherscan API (v2) for changed contracts
 * 5. Extracts ABIs from per-tag Forge caches (git tag per env contract `version`)
 * 6. Combines into a delta registry with previousRegistry pointer
 *
 * Output shape ("modes"):
 *   - delta:  normal append onto the live tip; `registry.version` is the new resolved version;
 *             `previousRegistry` points at the live. Used when the new version is strictly newer
 *             than the live (the common case).
 *   - patch:  same `previousRegistry` (live), but `registry.version` is **null**. The indexer
 *             (`api-v3/scripts/fetch-registry.mjs::mergeNullVersionPatchesIntoPredecessors`)
 *             merges a null-version layer into its chronological predecessor — so a patch
 *             effectively "replaces the last registry" without orphaning anything.
 *             Used when the local-resolved version equals the live tip's version (e.g. a
 *             follow-up PR adding more contracts to the same protocol version, or fixing up
 *             a contract missed in the previous publish).
 *   - full:   no `previousRegistry`; the registry is a base snapshot of all contracts.
 *
 * Auto-mode picks `patch` when local version matches the live version, otherwise `delta`.
 *
 * Usage:
 *   # Auto-mode (default — picks delta or patch based on version match):
 *   DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> node script/registry/abi-registry.js [mainnet|testnet]
 *
 *   # Force a normal delta append even when versions match:
 *   REGISTRY_MODE=delta DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> node script/registry/abi-registry.js [mainnet|testnet]
 *
 *   # Force a null-version patch (only meaningful when there is a live to patch onto):
 *   REGISTRY_MODE=patch DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> node script/registry/abi-registry.js [mainnet|testnet]
 *
 *   # Full snapshot mode (rebuild from scratch, no previousRegistry):
 *   DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> node script/registry/abi-registry.js [mainnet|testnet] --full
 *
 *   # Delta with explicit previous IPFS hash (rare; e.g. regenerate against a pinned older version):
 *   DEPLOYMENT_COMMIT=<commit> ETHERSCAN_API_KEY=<key> SOURCE_IPFS=Qm... node script/registry/abi-registry.js [mainnet|testnet]
 *
 * Environment Variables:
 *   - DEPLOYMENT_COMMIT: Git commit hash used to build the ABIs (required in CI)
 *   - ETHERSCAN_API_KEY: API key for Etherscan v2 API (required for block number fetching)
 *   - REGISTRY_MODE: One of "auto" (default), "delta", "patch", "full". Overrides --full when set.
 *   - SOURCE_IPFS: IPFS hash (CID) of previous registry to compare against (Qm... or bafy...)
 *   - ALLOW_PARTIAL_REGISTRY_CHAIN: "1" to generate even when the published chain cannot be fully
 *     walked. Off by default — a partial chain understates what is already published, which
 *     inflates the delta and drops deprecations.
 *   - REGISTRY_CHAIN_MAX_DEPTH: Integer >= 1 bounding how many registry layers the chain walk may
 *     hold (default in utils/registry-chain.js). Only needed if the chain outgrows that bound.
 *   - REGISTRY_CHAIN_CACHE_DIR / REGISTRY_CHAIN_NO_CACHE: Relocate or disable the on-disk cache of
 *     fetched layers (see utils/registry-fetch.js). Caching is an optimization; it is skipped
 *     silently when the directory is unwritable.
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
import {
    artifactNamesForContractKey,
    collectContractTags,
    ensureAbiCache,
    findAbiInOutput,
    getAbiCacheRoot,
    getCachedOutDir,
    resolveArtifactName,
} from "./utils/abi-cache.js";
import { collectRegistryChain, summarizeAccumulatedState } from "./utils/registry-chain.js";
import { computeChainDelta } from "./utils/registry-delta.js";
import {
    fetchLiveRegistry,
    fetchRegistryFromIpfs,
    isValidIpfsHash,
    resolveLiveCid,
} from "./utils/registry-fetch.js";

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

// Mode selection — the union of --full (CLI) and REGISTRY_MODE (env). Env takes precedence
// when set to a recognised value. Valid values:
//   - "auto"  : default; pick patch when local version equals live, otherwise delta.
//   - "delta" : force delta append (skip patch promotion even when versions match).
//   - "patch" : force a null-version patch (errors out if no live to patch onto).
//   - "full"  : force full snapshot (no previousRegistry; same as --full).
const VALID_MODES = new Set(["auto", "delta", "patch", "full"]);
let registryMode = "auto";
if (process.env.REGISTRY_MODE != null && process.env.REGISTRY_MODE !== "") {
    const requested = String(process.env.REGISTRY_MODE).toLowerCase();
    if (!VALID_MODES.has(requested)) {
        console.error(
            `Invalid REGISTRY_MODE "${process.env.REGISTRY_MODE}". Expected one of: ${[...VALID_MODES].join(", ")}.`
        );
        process.exit(1);
    }
    registryMode = requested;
}
if (registryMode === "full" || fullMode) {
    fullMode = true;
    registryMode = "full";
}

// Get SOURCE_IPFS from environment
const sourceIpfs = process.env.SOURCE_IPFS || null;

// Escape hatch for a registry chain that cannot be fully reconstructed (broken previousRegistry
// pointer, unreachable IPFS layer). Off by default: an incomplete chain understates what is
// already published, which inflates the delta towards a full snapshot and drops deprecations.
const allowPartialChain = process.env.ALLOW_PARTIAL_REGISTRY_CHAIN === "1";

// Optional override for how many registry layers the chain walk may fetch (default in
// utils/registry-chain.js). Only useful if the published chain ever outgrows that bound.
const registryChainMaxDepth = process.env.REGISTRY_CHAIN_MAX_DEPTH
    ? Number(process.env.REGISTRY_CHAIN_MAX_DEPTH)
    : undefined;
if (registryChainMaxDepth != null && (!Number.isInteger(registryChainMaxDepth) || registryChainMaxDepth < 1)) {
    console.error(
        `Invalid REGISTRY_CHAIN_MAX_DEPTH "${process.env.REGISTRY_CHAIN_MAX_DEPTH}". Expected an integer >= 1.`
    );
    process.exit(1);
}

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
 * Fetches the registry the delta is measured against: the live tip, or a specific CID when
 * SOURCE_IPFS pins the comparison to an older layer.
 *
 * @param {string} environment - "mainnet" or "testnet"
 * @param {string|null} ipfsHash - Optional IPFS hash (CID) to fetch from IPFS instead of the tip
 * @returns {Promise<Object|null>} The registry document, or null if it cannot be read
 */
async function fetchCurrentRegistry(environment, ipfsHash = null) {
    let registry = null;

    if (ipfsHash) {
        console.log(`Fetching registry from IPFS hash: ${ipfsHash}...`);
        try {
            registry = await fetchRegistryFromIpfs(ipfsHash, { log: (msg) => console.log(msg) });
        } catch (error) {
            console.warn(`Could not fetch registry ${ipfsHash}: ${error.message}`);
            return null;
        }
    } else {
        registry = await fetchLiveRegistry(environment);
        if (!registry) return null;
    }

    console.log(
        `  ✓ Fetched registry with version: ${registry.version || registry.deploymentInfo?.gitCommit || "unknown"}`
    );
    return registry;
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
 * 1. Fetch current live registry from registry.centrifuge.io and flatten its chain into the
 *    accumulated published state (unless in full mode)
 * 2. Process each chain in env/*.json matching the environment
 * 3. Compare contracts against the accumulated state to detect what's changed (unless in full mode)
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
    let publishedAbiNames = null; // null = no chain to compare ABI coverage against
    let previousVersion = null;
    let previousIpfsHash = sourceIpfs; // Use SOURCE_IPFS if provided

    if (!fullMode) {
        if (sourceIpfs) {
            console.log(`  Using IPFS hash for previousRegistry: ${sourceIpfs}`);
        }

        currentRegistry = await fetchCurrentRegistry(selector, sourceIpfs);
        previousVersion = currentRegistry?.version || currentRegistry?.deploymentInfo?.gitCommit || null;

        // No tip means no published state to measure against, and every env contract then reads as
        // new — the same inflated snapshot-as-a-delta an incomplete chain produces, except it also
        // leaves previousRegistry null and so presents itself as a base registry. An outage must not
        // be able to publish that; deliberately republishing a base snapshot is what full mode is
        // for, which is why there is no override here.
        if (!currentRegistry) {
            console.error(
                `\n✗ Refusing to generate the ${selector} registry: could not read the published ` +
                `tip${sourceIpfs ? ` at SOURCE_IPFS ${sourceIpfs}` : ""}.\n` +
                `  A delta is measured against published state; without it every contract would be ` +
                `re-emitted as new and the result would be pinned as a base registry.\n` +
                `  Re-run once the registry endpoint or IPFS is reachable, or set REGISTRY_MODE=full ` +
                `to publish a base snapshot on purpose.`
            );
            process.exitCode = 1;
            return;
        }

        if (sourceIpfs) {
            console.log(`  Comparing against registry version: ${previousVersion || "unknown"}`);
        }

        // Compare against the accumulated state of the whole published chain, not just the tip.
        // Each layer only carries what changed in that publish, so the tip alone would make every
        // contract it omits look new — a "delta" that is really a full snapshot.
        console.log(`  Reconstructing published state from the registry chain...`);
        const { layers, accumulated, accumulatedAbis, complete, reason, fatal } = await collectRegistryChain(currentRegistry, {
            maxDepth: registryChainMaxDepth,
            expectedNetwork: selector,
            log: console.log,
        });

        if (!complete) {
            // One write, and no process.exit: under Actions stderr is a pipe and therefore
            // async, so exiting here could truncate the very diagnostic that explains the
            // failure. Setting exitCode lets Node flush and exit on its own.
            if (fatal) {
                // Not a transient condition — the chain belongs to another environment, so
                // there is nothing to retry and no override that would make it safe.
                console.error(
                    `\n✗ Refusing to generate the ${selector} registry: ${reason}.\n` +
                    `  Check SOURCE_IPFS (or the live ${selector} dnslink) points at a ` +
                    `${selector} registry.`
                );
                process.exitCode = 1;
                return;
            }
            const message =
                `Could not reconstruct the full registry chain for ${selector}: ${reason}. ` +
                `Comparing against a partial chain would emit contracts that are already ` +
                `published and would miss deprecations.`;
            if (!allowPartialChain) {
                console.error(
                    `\n✗ ${message}\n` +
                    `  Re-run once IPFS is reachable, or set ALLOW_PARTIAL_REGISTRY_CHAIN=1 to ` +
                    `generate against the ${layers.length} layer(s) that were reachable.`
                );
                process.exitCode = 1;
                return;
            }
            console.warn(`  ⚠ ${message}`);
            console.warn(`  ⚠ ALLOW_PARTIAL_REGISTRY_CHAIN=1 — continuing with a partial chain.`);
        }

        currentChains = accumulated;
        // ABI coverage across the chain, so a contract whose ABI was never published can be
        // pulled into this delta even when its address has not moved (see computeChainDelta).
        publishedAbiNames = accumulatedAbis;
        const { chains: accChains, contracts: accContracts } =
            summarizeAccumulatedState(currentChains);
        console.log(
            `  ✓ Accumulated state from ${layers.length} layer(s): ` +
            `${accContracts} contracts across ${accChains} chain(s), ` +
            `${publishedAbiNames.size} ABIs`
        );

        // Resolve the live CID via DNS if not explicitly provided
        if (!previousIpfsHash && previousVersion) {
            previousIpfsHash = await resolveLiveCid(selector);
        }
    } else {
        console.log(`  Skipping registry fetch (full mode - no comparison)`);
        // In full mode, set previousRegistry to null to mark this as the base registry
        previousVersion = null;
    }

    // Forced-patch mode requires a live to patch onto.
    if (registryMode === "patch" && !currentRegistry) {
        console.error(
            `REGISTRY_MODE=patch but no live registry was found for ${selector}. ` +
            `A patch must point at an existing previousRegistry.`
        );
        process.exit(1);
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
    let totalAbiGapsHealed = 0;
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

        // Accumulated published state for this chain, merged across every registry layer
        // (null in full mode)
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
            // Delta mode: compare against the accumulated state of the whole published chain
            const allContracts = chain.contracts || {};
            const { changed: changedContractNames, deprecated, abiGaps } = computeChainDelta(
                allContracts,
                currentRegistryChain,
                { publishedAbiNames, abiNamesForContract: artifactNamesForContractKey }
            );

            totalContracts += Object.keys(allContracts).length;
            totalChangedContracts += changedContractNames.size;

            for (const [contractName, tombstone] of Object.entries(deprecated)) {
                processedContracts[contractName] = tombstone;
                totalDeprecatedContracts++;
                console.log(`    ⊘ ${contractName}: deprecated (removed from env)`);
            }
            const chainDeprecated = Object.keys(deprecated).length;

            for (const contractName of abiGaps) {
                totalAbiGapsHealed++;
                console.log(`    ⟲ ${contractName}: unchanged, re-emitted to ship an ABI the chain never carried`);
            }

            console.log(`  Found ${changedContractNames.size}/${Object.keys(allContracts).length} changed contracts` +
                (abiGaps.size > 0 ? ` (${abiGaps.size} to heal missing ABIs)` : "") +
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

    // Resolve the effective output mode now that we know both the live tip's version and the
    // version computed from the local env. Auto-mode picks `patch` when versions match (so the
    // indexer's null-version merge layer "replaces the last registry" without orphaning it),
    // otherwise `delta`. Forced modes (delta/patch/full) are honoured if reachable.
    const liveVersion = currentRegistry?.version ?? null;
    let effectiveMode = registryMode;
    if (effectiveMode === "auto") {
        if (
            currentRegistry &&
            typeof resolvedVersion === "string" &&
            typeof liveVersion === "string" &&
            compareProtocolVersionStrings(resolvedVersion, liveVersion) === 0
        ) {
            effectiveMode = "patch";
        } else {
            effectiveMode = "delta";
        }
    }
    if (effectiveMode === "patch" && !currentRegistry) {
        // Should be unreachable after the earlier guard, but keep an explicit check.
        console.error("Patch mode selected but no live registry to patch onto — aborting.");
        process.exit(1);
    }

    if (effectiveMode === "patch") {
        if (typeof liveVersion === "string" && typeof resolvedVersion === "string") {
            console.log(
                `\nMode: patch — local ${resolvedVersion} matches live ${liveVersion}; ` +
                `emitting a null-version patch (indexer will merge it into the live).`
            );
        } else {
            console.log("\nMode: patch — emitting a null-version patch.");
        }
    } else if (effectiveMode === "delta") {
        console.log(
            `\nMode: delta — local ${resolvedVersion || "unknown"} append onto live ` +
            `${liveVersion || "(none)"}.`
        );
    } else if (effectiveMode === "full") {
        console.log("\nMode: full — base snapshot, no previousRegistry.");
    }

    // Initialize registry structure. In patch mode the top-level version is intentionally null:
    // api-v3 fetch-registry treats a null-version layer as a patch on the chronologically previous
    // entry. In delta/full mode we emit the resolved version.
    const emitVersion = effectiveMode === "patch" ? null : resolvedVersion || null;
    const registry = {
        network: selector,
        version: emitVersion,
        deploymentInfo: {
            gitCommit: resolveDeploymentCommit(deploymentCommitOverride, deploymentCommits),
        },
        // previousRegistry pointer — ipfsHash resolved from SOURCE_IPFS env var, or via DNS
        // dnslink lookup on the live registry hostname. Null in full mode.
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
    if (effectiveMode === "full") {
        console.log(`\n=== Full Registry Summary ===`);
        console.log(`  Mode: full (base snapshot)`);
        console.log(`  Version: ${resolvedVersion || "unknown"}`);
        console.log(`  Previous version: none (base registry)`);
        console.log(`  Total contracts: ${totalContracts}`);
        console.log(`  Chains included: ${Object.keys(chains).length}`);
        console.log(`  ABIs included: ${Object.keys(registry.abis).length}`);
    } else {
        const headerMode =
            effectiveMode === "patch" ? "Patch (null-version)" : "Delta";
        console.log(`\n=== ${headerMode} Registry Summary ===`);
        console.log(`  Mode: ${effectiveMode}`);
        if (effectiveMode === "patch") {
            console.log(
                `  Patching live: ${liveVersion || "unknown"} ` +
                `(local resolved as ${resolvedVersion || "unknown"})`
            );
            console.log(`  Output version: null (indexer merges patch into predecessor)`);
        } else {
            console.log(`  Version: ${resolvedVersion || "unknown"}`);
            console.log(`  Previous version: ${previousVersion || "none (first registry)"}`);
        }
        // The two counters are independent: a deprecated contract is by definition absent from
        // env, so it can never be counted as changed. Keep them in separate clauses — a
        // parenthesised "(N deprecated)" reads as "N of those M".
        console.log(`  Changed contracts: ${totalChangedContracts}/${totalContracts}` +
            (totalDeprecatedContracts > 0 ? `, plus ${totalDeprecatedContracts} deprecated` : ""));
        const deltaEntries = totalChangedContracts + totalDeprecatedContracts;
        console.log(`  Contracts in delta: ${deltaEntries}`);
        if (totalAbiGapsHealed > 0) {
            console.log(`  Unchanged contracts re-emitted to heal missing ABIs: ${totalAbiGapsHealed}`);
        }
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
    const writtenLabel =
        effectiveMode === "full"
            ? "Full"
            : effectiveMode === "patch"
                ? "Patch (null-version)"
                : "Delta";
    console.log(`\n${writtenLabel} registry written to ${outputPath}`);
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

// No process.exit() in either handler: stdout/stderr are pipes in CI and therefore async, so
// exiting explicitly can truncate the diagnostic that explains a failure. Setting exitCode lets
// Node flush and exit on its own. `.then` runs before `.catch` so a rejection cannot be reported
// as a success, and main() bailing out after printing why is respected via exitCode.
main()
    .then(() => {
        if (process.exitCode) return;
        console.log("Registry built successfully");
    })
    .catch((error) => {
        console.error(error);
        process.exitCode = 1;
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
