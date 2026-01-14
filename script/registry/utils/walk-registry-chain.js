#!/usr/bin/env node
/**
 * @fileoverview Walks through the chain of registry versions via IPFS.
 * 
 * This script traverses the linked list of registries using previousRegistry.ipfsHash
 * pointers. It fetches each registry from IPFS and validates the chain, helping to
 * identify anomalies and determine rollback points.
 * 
 * Features:
 * - Chain traversal via previousRegistry.ipfsHash links
 * - Version timeline with semantic version progression
 * - Anomaly detection (version regressions, missing links, invalid data)
 * - Summary table with CID, version, date, and status
 * 
 * Usage:
 *   # Start from live registry
 *   node script/registry/walk-registry-chain.js testnet
 *   node script/registry/walk-registry-chain.js mainnet
 *   
 *   # Start from specific IPFS hash
 *   node script/registry/walk-registry-chain.js --cid bafkreiXXXX
 *   
 *   # Limit depth
 *   node script/registry/walk-registry-chain.js mainnet --depth 5
 */

// Registry URLs for fetching live registries
const REGISTRY_URLS = {
    mainnet: "https://registry.centrifuge.io",
    testnet: "https://registry.testnet.centrifuge.io",
};

// IPFS gateways to try (in order)
const IPFS_GATEWAYS = [
    "https://gateway.pinata.cloud/ipfs/",
    "https://ipfs.io/ipfs/",
    "https://cloudflare-ipfs.com/ipfs/",
];

// Parse CLI arguments
const args = process.argv.slice(2);
let network = null;
let startCid = null;
let maxDepth = 20;

for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--cid" && args[i + 1]) {
        startCid = args[++i];
    } else if (arg === "--depth" && args[i + 1]) {
        maxDepth = parseInt(args[++i], 10);
    } else if (arg === "mainnet" || arg === "testnet") {
        network = arg;
    }
}

if (!network && !startCid) {
    console.error("Usage: node walk-registry-chain.js <mainnet|testnet> [--depth N]");
    console.error("       node walk-registry-chain.js --cid <ipfs-hash> [--depth N]");
    console.error("\nExamples:");
    console.error("  node walk-registry-chain.js testnet");
    console.error("  node walk-registry-chain.js mainnet --depth 10");
    console.error("  node walk-registry-chain.js --cid bafkreiabc123xyz");
    process.exit(1);
}

/**
 * Parses a version string into comparable parts.
 */
function parseVersion(version) {
    if (!version) return null;
    
    const normalized = version.replace(/^v/, "");
    const parts = normalized.split("-");
    const versionPart = parts[0];
    const prerelease = parts.slice(1).join("-") || null;
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
    
    if (!pa || !pb) return 0;
    
    if (pa.major !== pb.major) return pa.major > pb.major ? 1 : -1;
    if (pa.minor !== pb.minor) return pa.minor > pb.minor ? 1 : -1;
    if (pa.patch !== pb.patch) return pa.patch > pb.patch ? 1 : -1;
    
    if (pa.prerelease && !pb.prerelease) return -1;
    if (!pa.prerelease && pb.prerelease) return 1;
    
    if (pa.prerelease && pb.prerelease) {
        return pa.prerelease.localeCompare(pb.prerelease);
    }
    
    return 0;
}

/**
 * Fetches a registry from the live URL.
 */
async function fetchLiveRegistry(network) {
    const url = REGISTRY_URLS[network];
    if (!url) {
        throw new Error(`Unknown network: ${network}`);
    }
    
    console.log(`Fetching live registry from ${url}...`);
    
    const response = await fetch(url);
    if (!response.ok) {
        throw new Error(`Failed to fetch: ${response.status} ${response.statusText}`);
    }
    
    return response.json();
}

/**
 * Fetches a registry from IPFS using multiple gateways.
 */
async function fetchFromIpfs(cid) {
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
 * Truncates a CID for display.
 */
function truncateCid(cid) {
    if (!cid) return "(none)";
    if (cid.length <= 20) return cid;
    return `${cid.slice(0, 10)}...${cid.slice(-6)}`;
}

/**
 * Formats a table row with fixed column widths.
 */
function formatRow(num, version, gitCommit, cid, chains, status) {
    const numStr = String(num).padStart(2);
    const versionStr = (version || "(none)").padEnd(12);
    const commitStr = (gitCommit || "-").padEnd(10);
    const cidStr = truncateCid(cid).padEnd(20);
    const chainsStr = String(chains).padEnd(6);
    
    return `| ${numStr} | ${versionStr} | ${commitStr} | ${cidStr} | ${chainsStr} | ${status}`;
}

/**
 * Walks the registry chain and collects data.
 */
async function walkChain(startRegistry, startCid) {
    const chain = [];
    const anomalies = [];
    
    let current = startRegistry;
    let currentCid = startCid || "(live)";
    let depth = 0;
    
    while (current && depth < maxDepth) {
        depth++;
        
        const version = current.version || current.deploymentInfo?.gitCommit;
        const gitCommit = current.deploymentInfo?.gitCommit;
        const chainCount = Object.keys(current.chains || {}).length;
        const previousCid = current.previousRegistry?.ipfsHash;
        const previousVersion = current.previousRegistry?.version;
        
        let status = "OK";
        
        // Check for anomalies
        if (chain.length > 0) {
            const prev = chain[chain.length - 1];
            
            // Version regression check
            if (version && prev.version) {
                const cmp = compareVersions(version, prev.version);
                if (cmp > 0) {
                    status = "WARN: version higher than newer";
                    anomalies.push({
                        depth,
                        message: `Registry #${depth}: version "${version}" is higher than #${depth - 1} "${prev.version}" (version went backwards)`,
                    });
                }
            }
            
            // Chain count decrease check (might indicate issues)
            if (chainCount > prev.chainCount) {
                // This registry has MORE chains than the newer one
                // This could be normal if chains were removed, or could indicate an issue
            }
        }
        
        // Missing required fields
        if (!version) {
            status = "WARN: missing version";
            anomalies.push({
                depth,
                message: `Registry #${depth}: missing version field`,
            });
        }
        
        if (!gitCommit) {
            status = status === "OK" ? "WARN: missing gitCommit" : status;
            anomalies.push({
                depth,
                message: `Registry #${depth}: missing deploymentInfo.gitCommit`,
            });
        }
        
        chain.push({
            depth,
            version,
            gitCommit,
            cid: currentCid,
            chainCount,
            previousCid,
            previousVersion,
            status,
        });
        
        // Move to previous registry
        if (!previousCid) {
            // End of chain
            chain.push({
                depth: depth + 1,
                version: "(end)",
                gitCommit: "-",
                cid: "-",
                chainCount: "-",
                previousCid: null,
                previousVersion: null,
                status: "Chain terminates",
            });
            break;
        }
        
        // Fetch previous registry
        try {
            console.log(`  Fetching previous registry: ${truncateCid(previousCid)}...`);
            current = await fetchFromIpfs(previousCid);
            currentCid = previousCid;
        } catch (error) {
            anomalies.push({
                depth: depth + 1,
                message: `Failed to fetch previous registry ${truncateCid(previousCid)}: ${error.message}`,
            });
            chain.push({
                depth: depth + 1,
                version: "(error)",
                gitCommit: "-",
                cid: previousCid,
                chainCount: "-",
                previousCid: null,
                previousVersion: null,
                status: `FAIL: ${error.message}`,
            });
            break;
        }
    }
    
    if (depth >= maxDepth) {
        chain.push({
            depth: depth + 1,
            version: "(truncated)",
            gitCommit: "-",
            cid: "-",
            chainCount: "-",
            previousCid: null,
            previousVersion: null,
            status: `Max depth ${maxDepth} reached`,
        });
    }
    
    return { chain, anomalies };
}

/**
 * Prints the chain table.
 */
function printChainTable(chain) {
    console.log("\n" + "─".repeat(80));
    console.log("| #  | Version      | Git Commit | IPFS CID             | Chains | Status");
    console.log("|" + "─".repeat(78) + "|");
    
    for (const entry of chain) {
        console.log(formatRow(
            entry.depth,
            entry.version,
            entry.gitCommit,
            entry.cid,
            entry.chainCount,
            entry.status
        ));
    }
    
    console.log("─".repeat(80));
}

/**
 * Prints anomalies and recommendations.
 */
function printAnomalies(anomalies, chain) {
    if (anomalies.length === 0) {
        console.log("\n✅ No anomalies detected in the registry chain.");
        return;
    }
    
    console.log("\n⚠️  Anomalies detected:");
    for (const anomaly of anomalies) {
        console.log(`  - ${anomaly.message}`);
    }
    
    // Find the last "OK" registry for rollback recommendation
    const okRegistries = chain.filter(r => r.status === "OK" && r.cid !== "(live)" && r.cid !== "-");
    if (okRegistries.length > 0) {
        const lastOk = okRegistries[0]; // First OK after current (which might be bad)
        console.log(`\n📋 Recommendation: If current registry is bad, consider rollback to:`);
        console.log(`   CID: ${lastOk.cid}`);
        console.log(`   Version: ${lastOk.version}`);
    }
}

/**
 * Main function.
 */
async function main() {
    let startRegistry;
    let registryCid = startCid;
    
    if (startCid) {
        console.log(`\n=== Registry Chain Walk (from CID) ===\n`);
        console.log(`Starting from IPFS CID: ${startCid}\n`);
        startRegistry = await fetchFromIpfs(startCid);
    } else {
        console.log(`\n=== Registry Chain Walk: ${network} ===\n`);
        startRegistry = await fetchLiveRegistry(network);
    }
    
    console.log(`\nWalking chain (max depth: ${maxDepth})...\n`);
    
    const { chain, anomalies } = await walkChain(startRegistry, registryCid);
    
    printChainTable(chain);
    printAnomalies(anomalies, chain);
    
    // Print statistics
    const okCount = chain.filter(r => r.status === "OK").length;
    const warnCount = chain.filter(r => r.status.startsWith("WARN")).length;
    const failCount = chain.filter(r => r.status.startsWith("FAIL")).length;
    
    console.log(`\nChain statistics:`);
    console.log(`  Total registries: ${chain.length - 1}`); // Exclude the terminator
    console.log(`  OK: ${okCount}, Warnings: ${warnCount}, Failures: ${failCount}`);
    
    if (failCount > 0) {
        process.exit(1);
    }
}

main().catch((error) => {
    console.error(`\nError: ${error.message}`);
    process.exit(1);
});




