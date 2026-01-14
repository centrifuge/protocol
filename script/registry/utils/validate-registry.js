#!/usr/bin/env node
/**
 * @fileoverview Validates a registry JSON file before pinning to IPFS.
 * 
 * This script performs comprehensive validation checks on a registry file:
 * - Each chain has a startBlock value
 * - startBlock is higher than the previous registry's startBlock (if previous exists)
 * - Chain network and adapters match environment files exactly (including type checking)
 * - Git commit exists in git history
 * - Version is a valid semantic version
 * - Previous version (if any) is semantically lower
 * - Contract addresses are valid Ethereum addresses
 * - All referenced contracts have corresponding ABI entries
 * - No empty chains
 * 
 * Usage:
 *   node script/registry/utils/validate-registry.js registry/registry-testnet.json
 *   node script/registry/utils/validate-registry.js registry/registry-mainnet.json --compare-live
 * 
 * Options:
 *   --compare-live    Fetch the current live registry to compare versions and startBlocks
 *   --quiet           Only show failures and warnings, not passes
 */

import { readFileSync, existsSync, readdirSync } from "fs";
import { execSync } from "child_process";
import { basename, join } from "path";

// Parse CLI arguments
const args = process.argv.slice(2);
let registryPath = null;
let compareLive = false;
let quietMode = false;

for (const arg of args) {
    if (arg === "--compare-live") {
        compareLive = true;
    } else if (arg === "--quiet") {
        quietMode = true;
    } else if (!arg.startsWith("--")) {
        registryPath = arg;
    }
}

if (!registryPath) {
    console.error("Usage: node validate-registry.js <registry-file> [--compare-live] [--quiet]");
    console.error("Example: node validate-registry.js registry/registry-testnet.json --compare-live");
    process.exit(1);
}

// Registry URLs for fetching live registries
const REGISTRY_URLS = {
    mainnet: "https://registry.centrifuge.io",
    testnet: "https://registry.testnet.centrifuge.io",
};

// Validation result tracking
const results = {
    passed: 0,
    warnings: 0,
    failures: 0,
};

function pass(message) {
    results.passed++;
    if (!quietMode) {
        console.log(`[PASS] ${message}`);
    }
}

function warn(message) {
    results.warnings++;
    console.log(`[WARN] ${message}`);
}

function fail(message) {
    results.failures++;
    console.log(`[FAIL] ${message}`);
}

/**
 * Validates that a string is a valid Ethereum address (0x + 40 hex chars).
 * Does not check checksum, just format.
 */
function isValidAddress(address) {
    if (typeof address !== "string") return false;
    return /^0x[a-fA-F0-9]{40}$/.test(address);
}

/**
 * Validates that a version string matches semantic versioning patterns.
 * Accepts: v3.1, 3.1.0, v3.1.2, v3-main, 3.0.0-beta.1
 */
function isValidSemanticVersion(version) {
    if (typeof version !== "string" || version.length === 0) return false;

    // Accept patterns like: v3.1, 3.1.0, v3.1.2, v3-main, 3.0.0-beta.1
    // Basic semver pattern with optional 'v' prefix and optional pre-release suffix
    const semverPattern = /^v?\d+(\.\d+)?(\.\d+)?(-[a-zA-Z0-9.-]+)?$/;
    return semverPattern.test(version);
}

/**
 * Parses a version string into comparable parts.
 * Returns { major, minor, patch, prerelease } or null if invalid.
 */
function parseVersion(version) {
    if (!version) return null;

    // Remove 'v' prefix
    const normalized = version.replace(/^v/, "");

    // Check for pre-release suffix (e.g., -main, -beta.1)
    const parts = normalized.split("-");
    const versionPart = parts[0];
    const prerelease = parts.slice(1).join("-") || null;

    // Parse major.minor.patch
    const nums = versionPart.split(".").map(n => parseInt(n, 10));

    return {
        major: nums[0] || 0,
        minor: nums[1] || 0,
        patch: nums[2] || 0,
        prerelease,
    };
}

/**
 * Compares two versions. Returns:
 *   -1 if a < b
 *    0 if a == b
 *    1 if a > b
 */
function compareVersions(a, b) {
    const pa = parseVersion(a);
    const pb = parseVersion(b);

    if (!pa || !pb) return 0; // Can't compare, treat as equal

    // Compare major.minor.patch
    if (pa.major !== pb.major) return pa.major > pb.major ? 1 : -1;
    if (pa.minor !== pb.minor) return pa.minor > pb.minor ? 1 : -1;
    if (pa.patch !== pb.patch) return pa.patch > pb.patch ? 1 : -1;

    // Pre-release versions are lower than release versions
    if (pa.prerelease && !pb.prerelease) return -1;
    if (!pa.prerelease && pb.prerelease) return 1;

    // Both have pre-release, compare alphabetically
    if (pa.prerelease && pb.prerelease) {
        return pa.prerelease.localeCompare(pb.prerelease);
    }

    return 0;
}

/**
 * Checks if a git commit exists in the repository history.
 */
function gitCommitExists(commit) {
    try {
        execSync(`git cat-file -t ${commit}`, {
            stdio: ["pipe", "pipe", "pipe"],
            encoding: "utf8"
        });
        return true;
    } catch {
        return false;
    }
}

/**
 * Fetches the live registry from the appropriate URL.
 */
async function fetchLiveRegistry(network) {
    const url = REGISTRY_URLS[network];
    if (!url) {
        throw new Error(`Unknown network: ${network}`);
    }

    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`Failed to fetch live registry: ${response.status}`);
    }
    return response.json();
}

/**
 * Fetches a registry from IPFS using multiple gateways.
 */
async function fetchFromIpfs(cid) {
    const IPFS_GATEWAYS = [
        "https://gateway.pinata.cloud/ipfs/",
        "https://ipfs.io/ipfs/",
        "https://cloudflare-ipfs.com/ipfs/",
    ];

    for (const gateway of IPFS_GATEWAYS) {
        const url = `${gateway}${cid}`;
        try {
            const response = await fetch(url, {
                signal: AbortSignal.timeout(15000) // 15 second timeout
            });
            if (response.ok) {
                return response.json();
            }
        } catch (error) {
            // Try next gateway
            continue;
        }
    }

    throw new Error(`Failed to fetch from IPFS: ${cid}`);
}

/**
 * Builds a mapping from chainId to environment file data.
 * Reads all env/*.json files and maps them by chainId.
 */
function buildChainIdToEnvMap() {
    const envDir = join(process.cwd(), "env");
    const envFiles = readdirSync(envDir).filter(f => f.endsWith(".json") && f !== "example.json");
    const chainIdToEnv = new Map();

    for (const envFile of envFiles) {
        const envPath = join(envDir, envFile);
        try {
            const envData = JSON.parse(readFileSync(envPath, "utf8"));
            const chainId = envData.network?.chainId;
            if (chainId != null) {
                // Store as string key to match registry format
                chainIdToEnv.set(String(chainId), { file: envFile, data: envData });
            }
        } catch (error) {
            // Skip invalid JSON files
            continue;
        }
    }

    return chainIdToEnv;
}

/**
 * Deep compares two values, ensuring types match exactly (including number vs string).
 * Returns true if they are exactly equal (same structure and types).
 */
function deepEqualExact(a, b, path = "") {
    // Type check first
    if (typeof a !== typeof b) {
        return { equal: false, reason: `Type mismatch at ${path}: ${typeof a} vs ${typeof b}` };
    }

    // Null/undefined check
    if (a === null || a === undefined) {
        return { equal: a === b, reason: a === b ? null : `Null/undefined mismatch at ${path}` };
    }

    // Primitive comparison
    if (typeof a !== "object") {
        return { equal: a === b, reason: a === b ? null : `Value mismatch at ${path}: ${a} vs ${b}` };
    }

    // Array comparison
    if (Array.isArray(a)) {
        if (!Array.isArray(b)) {
            return { equal: false, reason: `Type mismatch at ${path}: array vs ${typeof b}` };
        }
        if (a.length !== b.length) {
            return { equal: false, reason: `Array length mismatch at ${path}: ${a.length} vs ${b.length}` };
        }
        for (let i = 0; i < a.length; i++) {
            const result = deepEqualExact(a[i], b[i], `${path}[${i}]`);
            if (!result.equal) {
                return result;
            }
        }
        return { equal: true, reason: null };
    }

    // Object comparison
    const aKeys = Object.keys(a).sort();
    const bKeys = Object.keys(b).sort();

    if (aKeys.length !== bKeys.length) {
        return { equal: false, reason: `Object key count mismatch at ${path}: ${aKeys.length} vs ${bKeys.length}` };
    }

    for (const key of aKeys) {
        if (!bKeys.includes(key)) {
            return { equal: false, reason: `Missing key in second object at ${path}.${key}` };
        }
        const result = deepEqualExact(a[key], b[key], path ? `${path}.${key}` : key);
        if (!result.equal) {
            return result;
        }
    }

    return { equal: true, reason: null };
}

/**
 * Validates that chain.network and chain.adapters match environment files exactly.
 */
function validateChainConfigMatchesEnv(registry) {
    const chains = registry.chains || {};
    const chainIds = Object.keys(chains);

    if (chainIds.length === 0) {
        fail("No chains found in registry");
        return;
    }

    const chainIdToEnv = buildChainIdToEnvMap();
    const issues = [];
    let allMatch = true;

    for (const chainId of chainIds) {
        const chain = chains[chainId];
        const envMapping = chainIdToEnv.get(chainId);

        if (!envMapping) {
            issues.push(`Chain ${chainId}: no matching environment file found`);
            allMatch = false;
            continue;
        }

        const envData = envMapping.data;

        // Prepare registry network and env network
        const registryNetwork = chain.network || {};
        const envNetwork = envData.network || {};

        // Compare all fields that exist in both registry and env file
        // Exclude fields that are deployment-only (environment, connectsTo)
        const fieldsToExclude = ["environment", "connectsTo"];
        const allNetworkFields = new Set([
            ...Object.keys(registryNetwork),
            ...Object.keys(envNetwork)
        ]);

        for (const field of allNetworkFields) {
            // Skip deployment-only fields
            if (fieldsToExclude.includes(field)) {
                continue;
            }

            // Only compare if field exists in both
            if (registryNetwork[field] !== undefined && envNetwork[field] !== undefined) {
                const regValue = registryNetwork[field];
                const envValue = envNetwork[field];
                const result = deepEqualExact(regValue, envValue, `chain ${chainId}.network.${field}`);
                if (!result.equal) {
                    issues.push(`Chain ${chainId}.network.${field}: ${result.reason}`);
                    allMatch = false;
                }
            } else if (registryNetwork[field] !== undefined && envNetwork[field] === undefined) {
                // Field in registry but not in env - this is OK (registry can have extra fields)
                continue;
            } else if (registryNetwork[field] === undefined && envNetwork[field] !== undefined) {
                // Field in env but not in registry - this might be an issue, but skip deployment-only fields
                if (!fieldsToExclude.includes(field)) {
                    issues.push(`Chain ${chainId}.network.${field}: missing in registry (exists in env file)`);
                    allMatch = false;
                }
            }
        }

        // Compare adapters - registry should match env exactly (excluding 'deploy' field from env)
        const registryAdapters = chain.adapters || {};
        const envAdapters = envData.adapters || {};

        // Remove 'deploy' field from env adapters for comparison
        const cleanedEnvAdapters = {};
        for (const [adapterName, adapterConfig] of Object.entries(envAdapters)) {
            const { deploy, ...adapterFields } = adapterConfig;
            cleanedEnvAdapters[adapterName] = adapterFields;
        }

        const result = deepEqualExact(registryAdapters, cleanedEnvAdapters, `chain ${chainId}.adapters`);
        if (!result.equal) {
            issues.push(`Chain ${chainId}.adapters: ${result.reason}`);
            allMatch = false;
        }
    }

    if (allMatch) {
        pass(`All ${chainIds.length} chains match their environment files`);
    } else {
        for (const issue of issues) {
            fail(issue);
        }
    }
}

/**
 * Validates startBlock for all chains.
 * Also checks that startBlock is higher than the previous registry's startBlock.
 */
function validateStartBlocks(registry, liveRegistry = null, previousRegistry = null) {
    const chains = registry.chains || {};
    const chainIds = Object.keys(chains);

    if (chainIds.length === 0) {
        fail("No chains found in registry");
        return;
    }

    let allHaveStartBlock = true;
    const issues = [];

    for (const chainId of chainIds) {
        const chain = chains[chainId];
        const deployment = chain.deployment || {};
        const startBlock = deployment.startBlock;

        if (startBlock == null || typeof startBlock !== "number" || startBlock <= 0) {
            allHaveStartBlock = false;
            issues.push(`Chain ${chainId}: missing or invalid startBlock`);
        } else {
            // Check against previous registry
            if (previousRegistry?.chains?.[chainId]?.deployment?.startBlock) {
                const prevStartBlock = previousRegistry.chains[chainId].deployment.startBlock;
                if (startBlock <= prevStartBlock) {
                    allHaveStartBlock = false;
                    issues.push(`Chain ${chainId}: startBlock ${startBlock} is not higher than previous registry's ${prevStartBlock}`);
                }
            }

            // Check against live registry (if provided)
            if (liveRegistry?.chains?.[chainId]?.deployment?.startBlock) {
                const liveStartBlock = liveRegistry.chains[chainId].deployment.startBlock;
                if (startBlock < liveStartBlock) {
                    warn(`Chain ${chainId}: startBlock ${startBlock} is lower than live ${liveStartBlock}`);
                }
            }
        }
    }

    if (allHaveStartBlock) {
        pass(`All ${chainIds.length} chains have valid startBlock values`);
    } else {
        for (const issue of issues) {
            fail(issue);
        }
    }
}

/**
 * Validates the git commit exists in history.
 */
function validateGitCommit(registry) {
    const commit = registry.deploymentInfo?.gitCommit;

    if (!commit) {
        fail("Missing deploymentInfo.gitCommit");
        return;
    }

    if (gitCommitExists(commit)) {
        pass(`Git commit "${commit}" exists in history`);
    } else {
        fail(`Git commit "${commit}" not found in git history`);
    }
}

/**
 * Validates the version is a valid semantic version.
 */
function validateVersion(registry) {
    const version = registry.version;

    if (!version) {
        fail("Missing version field");
        return;
    }

    if (isValidSemanticVersion(version)) {
        pass(`Version "${version}" is valid semantic version`);
    } else {
        fail(`Version "${version}" is not a valid semantic version`);
    }
}

/**
 * Validates previous registry version ordering.
 */
function validatePreviousVersion(registry) {
    const currentVersion = registry.version;
    const previousVersion = registry.previousRegistry?.version;

    if (!previousVersion) {
        pass("No previous registry version to compare (base registry)");
        return;
    }

    if (!currentVersion) {
        warn("Cannot compare versions: current version is missing");
        return;
    }

    const comparison = compareVersions(currentVersion, previousVersion);

    if (comparison > 0) {
        pass(`Version "${currentVersion}" is higher than previous "${previousVersion}"`);
    } else if (comparison === 0) {
        warn(`Version "${currentVersion}" is same as previous "${previousVersion}"`);
    } else {
        warn(`Version "${currentVersion}" appears lower than previous "${previousVersion}" (possible regression)`);
    }
}

/**
 * Validates all contract addresses are valid Ethereum addresses.
 */
function validateContractAddresses(registry) {
    const chains = registry.chains || {};
    let invalidAddresses = [];
    let totalContracts = 0;

    for (const [chainId, chain] of Object.entries(chains)) {
        const contracts = chain.contracts || {};

        for (const [contractName, contractData] of Object.entries(contracts)) {
            totalContracts++;
            const address = typeof contractData === "string"
                ? contractData
                : contractData?.address;

            if (!isValidAddress(address)) {
                invalidAddresses.push(`${chainId}/${contractName}: "${address}"`);
            }
        }
    }

    if (invalidAddresses.length === 0) {
        pass(`All ${totalContracts} contract addresses are valid`);
    } else {
        for (const invalid of invalidAddresses) {
            fail(`Invalid address: ${invalid}`);
        }
    }
}

/**
 * Validates that all contracts have corresponding ABI entries.
 */
function validateAbiCompleteness(registry) {
    const chains = registry.chains || {};
    const abis = registry.abis || {};
    const missingAbis = new Set();

    for (const chain of Object.values(chains)) {
        const contracts = Object.keys(chain.contracts || {});

        for (const contractName of contracts) {
            // Capitalize first letter to match ABI naming convention
            const abiName = contractName.charAt(0).toUpperCase() + contractName.slice(1);

            if (!abis[abiName]) {
                missingAbis.add(abiName);
            }
        }
    }

    const abiCount = Object.keys(abis).length;

    if (missingAbis.size === 0) {
        pass(`All ${abiCount} ABIs present for deployed contracts`);
    } else {
        for (const missing of missingAbis) {
            warn(`Missing ABI for contract: ${missing}`);
        }
    }
}

/**
 * Validates that no chains are empty.
 */
function validateNoEmptyChains(registry) {
    const chains = registry.chains || {};
    const emptyChains = [];

    for (const [chainId, chain] of Object.entries(chains)) {
        const contractCount = Object.keys(chain.contracts || {}).length;
        if (contractCount === 0) {
            emptyChains.push(chainId);
        }
    }

    if (emptyChains.length === 0) {
        pass(`All ${Object.keys(chains).length} chains have contracts`);
    } else {
        for (const chainId of emptyChains) {
            fail(`Chain ${chainId} has no contracts`);
        }
    }
}

/**
 * Validates network field matches expected values.
 */
function validateNetwork(registry) {
    const network = registry.network;

    if (!network) {
        fail("Missing network field");
        return;
    }

    if (network === "mainnet" || network === "testnet") {
        pass(`Network "${network}" is valid`);
    } else {
        warn(`Network "${network}" is not standard (expected "mainnet" or "testnet")`);
    }
}

/**
 * Main validation function.
 */
async function main() {
    // Check file exists
    if (!existsSync(registryPath)) {
        console.error(`Error: File not found: ${registryPath}`);
        process.exit(1);
    }

    // Load registry
    let registry;
    try {
        registry = JSON.parse(readFileSync(registryPath, "utf8"));
    } catch (error) {
        console.error(`Error: Failed to parse JSON: ${error.message}`);
        process.exit(1);
    }

    console.log(`\n=== Registry Validation: ${basename(registryPath)} ===\n`);

    // Fetch live registry if requested
    let liveRegistry = null;
    if (compareLive) {
        const network = registry.network || "testnet";
        console.log(`Fetching live ${network} registry for comparison...\n`);
        try {
            liveRegistry = await fetchLiveRegistry(network);
        } catch (error) {
            warn(`Could not fetch live registry: ${error.message}`);
            console.log("");
        }
    }

    // Fetch previous registry if it exists
    let previousRegistry = null;
    const previousIpfsHash = registry.previousRegistry?.ipfsHash;

    // If ipfsHash is missing, warn and suggest running the update script
    if (registry.previousRegistry && !previousIpfsHash) {
        warn("previousRegistry.ipfsHash is missing - cannot validate against previous registry");
        console.log("  Tip: Run 'node script/registry/pin-to-ipfs.js --update-previous' to update the local file");
        console.log("       This will query Pinata and populate previousRegistry.ipfsHash before validation\n");
    }

    if (previousIpfsHash) {
        console.log(`Fetching previous registry from IPFS: ${previousIpfsHash}...\n`);
        try {
            previousRegistry = await fetchFromIpfs(previousIpfsHash);
            console.log(`  ✓ Fetched previous registry version: ${previousRegistry.version || "unknown"}\n`);
        } catch (error) {
            warn(`Could not fetch previous registry from IPFS: ${error.message}`);
            console.log("");
        }
    }

    // Run all validations
    validateNetwork(registry);
    validateVersion(registry);
    validateGitCommit(registry);
    validatePreviousVersion(registry);
    validateChainConfigMatchesEnv(registry);
    validateStartBlocks(registry, liveRegistry, previousRegistry);
    validateContractAddresses(registry);
    validateAbiCompleteness(registry);
    validateNoEmptyChains(registry);

    // Print summary
    console.log(`\n${"─".repeat(50)}`);
    console.log(`Summary: ${results.passed} passed, ${results.warnings} warnings, ${results.failures} failures`);

    if (results.failures > 0) {
        console.log("\n❌ Validation FAILED - do not pin this registry");
        process.exit(1);
    } else if (results.warnings > 0) {
        console.log("\n⚠️  Validation passed with warnings - review before pinning");
        process.exit(0);
    } else {
        console.log("\n✅ Validation PASSED - safe to pin");
        process.exit(0);
    }
}

main().catch((error) => {
    console.error(`Error: ${error.message}`);
    process.exit(1);
});




