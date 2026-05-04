#!/usr/bin/env node
/**
 * @fileoverview Pins delta registry files to IPFS using Pinata SDK.
 * 
 * This script handles the pinning of delta registries and manages the version chain:
 * 1. If previousRegistry.ipfsHash is missing, resolves it via DNS dnslink lookup
 *    (falling back to Pinata metadata query)
 * 2. Pins the registry with version metadata for future lookups
 * 3. Outputs CID metadata for downstream steps (Cloudflare DNS update)
 * 
 * Usage:
 *   node script/registry/pin-to-ipfs.js [--force=mainnet|testnet] [--update-previous]
 * 
 * Arguments:
 *   --force=mainnet - Force pin mainnet registry even if unchanged
 *   --force=testnet - Force pin testnet registry even if unchanged
 *   --update-previous - Only update previousRegistry.ipfsHash in local files (no pinning)
 *                      Useful for updating registry files before validation
 * 
 * Environment variables:
 *   PINATA_JWT - Pinata JWT token (required)
 *   PINATA_GATEWAY - Pinata gateway domain (optional, defaults to "gateway.pinata.cloud")
 *   GITHUB_SHA - Git commit SHA for naming (optional, defaults to "latest")
 *   GITHUB_STEP_SUMMARY - Path to GitHub Actions step summary file (optional)
 *   FORCE_PIN - Set to "1" to force pin (alternative to --force flag)
 * 
 * Output: Prints JSON with IPFS hashes and change status to stdout:
 *   {"mainnet": {"cid": "Qm...", "changed": true}, "testnet": {"cid": "Qm...", "changed": true}}
 * 
 * Also writes GitHub Actions step summary if GITHUB_STEP_SUMMARY is set.
 */

import { PinataSDK } from "pinata";
import { readFileSync, existsSync, writeFileSync } from "fs";
import { join } from "path";
import { resolveTxt } from "dns/promises";
import * as core from "@actions/core";

const pinataJwt = process.env.PINATA_JWT;
const githubSha = process.env.GITHUB_SHA || "latest";

// Parse --force=mainnet or --force=testnet
const forceArg = process.argv.find(arg => arg.startsWith("--force="));
const forceEnv = forceArg ? forceArg.split("=")[1] : null;
// Also support FORCE_PIN=mainnet or FORCE_PIN=testnet
const forcePinEnv = process.env.FORCE_PIN || null;

// Parse --update-previous flag
const updatePrevious = process.argv.includes("--update-previous");

// Initialize Pinata SDK
// Gateway is optional (mainly for fetching), but SDK may require it
const pinataGateway = process.env.PINATA_GATEWAY || "gateway.pinata.cloud";

// Only require PINATA_JWT if we're actually pinning (not just updating previous)
if (!updatePrevious && !pinataJwt) {
    console.error("Error: PINATA_JWT environment variable is required");
    console.error("See: https://docs.pinata.cloud/frameworks/node-js");
    process.exit(1);
}

// Initialize Pinata SDK only if we have JWT (needed for both pinning and --update-previous)
let pinata = null;
if (pinataJwt) {
    pinata = new PinataSDK({
        pinataJwt: pinataJwt,
        pinataGateway: pinataGateway,
    });
}

const DNSLINK_HOSTNAMES = {
    mainnet: "registry.centrifuge.io",
    testnet: "registry.testnet.centrifuge.io",
};

/**
 * Resolves the IPFS CID of the currently live registry via DNS TXT lookup.
 *
 * @param {string} env - "mainnet" or "testnet"
 * @returns {Promise<string|null>} IPFS CID or null if not resolvable
 */
async function resolveLiveCid(env) {
    const hostname = DNSLINK_HOSTNAMES[env];
    if (!hostname) return null;

    const dnslinkHost = `_dnslink.${hostname}`;
    try {
        const records = await resolveTxt(dnslinkHost);
        for (const record of records) {
            const txt = record.join("");
            const match = txt.match(/^dnslink=\/ipfs\/(.+)$/);
            if (match) return match[1];
        }
        return null;
    } catch {
        return null;
    }
}

/**
 * Queries Pinata for the most recently pinned registry matching the environment.
 * Uses metadata filtering to find registries by env (mainnet/testnet).
 * 
 * @param {string} env - Environment to search for ("mainnet" or "testnet")
 * @returns {Promise<{cid: string, version: string}|null>} Previous registry info or null
 */
async function findPreviousRegistryCid(env) {
    if (!pinata) {
        throw new Error("Pinata SDK not initialized. PINATA_JWT is required.");
    }

    try {
        console.log(`Querying Pinata for previous ${env} registry...`);

        // List files with keyvalues filter for env
        // Pinata SDK returns { files: [...], next_page_token: "..." }
        // See: https://docs.pinata.cloud/sdk/files/public/list
        const response = await pinata.files.public.list()
            .keyvalues({ env: env })
            .order("DESC")
            .limit(10);

        const files = response?.files || [];

        if (files.length === 0) {
            console.log(`  No previous ${env} registry found in Pinata`);
            return null;
        }

        // Find the most recent pin that matches our naming convention
        for (const file of files) {
            // Our naming convention: registry-mainnet-<sha> or registry-testnet-<sha>
            if (file.name && file.name.startsWith(`registry-${env}`)) {
                const version = file.keyvalues?.version || null;
                console.log(`  ✓ Found previous registry: ${file.cid} (version: ${version || "unknown"})`);
                return {
                    cid: file.cid,
                    version: version,
                };
            }
        }

        console.log(`  No matching registry found in Pinata results`);
        return null;
    } catch (error) {
        console.warn(`  ⚠ Could not query Pinata for previous registry: ${error.message}`);
        return null;
    }
}

async function fetchExistingRegistry(url) {
    try {
        const response = await fetch(url);
        if (!response.ok) {
            return null;
        }
        return await response.json();
    } catch (error) {
        console.warn(`Could not fetch existing registry from ${url}: ${error.message}`);
        return null;
    }
}

function compareRegistries(existing, newContent) {
    if (!existing) return true; // No existing registry, consider it changed

    // Normalize both to strings for comparison (remove any formatting differences)
    // Use a replacer function to sort keys and exclude adapters from comparison
    // (adapters contain chainSelector which gets corrupted by JSON.parse due to exceeding MAX_SAFE_INTEGER)
    const replacer = (key, value) => {
        // Exclude adapters from comparison to avoid false positives from chainSelector corruption
        if (key === 'adapters') {
            return undefined;
        }
        if (value && typeof value === 'object' && !Array.isArray(value)) {
            const sorted = {};
            Object.keys(value).sort().forEach(k => {
                sorted[k] = value[k];
            });
            return sorted;
        }
        return value;
    };

    const existingStr = JSON.stringify(existing, replacer);
    const newStr = JSON.stringify(newContent, replacer);

    return existingStr !== newStr;
}

async function pinFile(filePath, name, existingUrl) {
    if (!existsSync(filePath)) {
        throw new Error(`File not found: ${filePath}`);
    }

    if (!pinata) {
        throw new Error("Pinata SDK not initialized. PINATA_JWT is required.");
    }

    // Determine environment from URL or name
    const inferredEnv =
        existingUrl?.includes("testnet") || name.toLowerCase().includes("testnet")
            ? "testnet"
            : "mainnet";

    // Check if force is enabled for this specific environment ("both" forces all envs)
    const shouldForce = (forceEnv === inferredEnv || forceEnv === "both") ||
                        (forcePinEnv === inferredEnv || forcePinEnv === "both");

    // Read original content as text to preserve large numbers like chainSelector
    const originalContent = readFileSync(filePath, "utf8");
    const newContent = JSON.parse(originalContent);

    // Guard: skip pinning when the delta has no contract changes (empty chains).
    // An empty delta means only metadata changed (env cleanup, CI scripts, etc.) — nothing
    // the indexer depends on. Force-pin bypasses this to allow manual corrections.
    const chainCount = Object.keys(newContent.chains || {}).length;
    if (chainCount === 0 && !shouldForce) {
        console.log(`Registry has zero chains (no contract changes), skipping pin for ${name}`);
        return { cid: null, changed: false };
    }

    // Fetch and compare with existing registry (skip if force flag is set for this env)
    if (!shouldForce) {
        const existing = existingUrl ? await fetchExistingRegistry(existingUrl) : null;
        const changed = compareRegistries(existing, newContent);

        if (!changed) {
            console.log(`Registry unchanged, skipping pin for ${name}`);
            return { cid: null, changed: false };
        }
        console.log(`Registry changed, pinning ${name}...`);
    } else {
        console.log(`Force pin enabled for ${inferredEnv}, pinning ${name}...`);
    }

    // Extract version from the registry content
    const version = newContent.version || newContent.deploymentInfo?.gitCommit || null;

    // The ipfsHash is normally resolved at generation time via DNS dnslink lookup
    // in abi-registry.js. If it's still null, try DNS then Pinata as fallback.
    if (newContent.previousRegistry && !newContent.previousRegistry.ipfsHash) {
        console.log(`  previousRegistry.ipfsHash not set, resolving via DNS...`);
        let resolvedCid = await resolveLiveCid(inferredEnv);
        if (!resolvedCid) {
            console.log(`  DNS failed, falling back to Pinata...`);
            const info = await findPreviousRegistryCid(inferredEnv);
            resolvedCid = info?.cid || null;
        }
        if (resolvedCid) {
            newContent.previousRegistry.ipfsHash = resolvedCid;
            console.log(`  Injected previousRegistry.ipfsHash: ${resolvedCid}`);
        }
    } else if (newContent.previousRegistry?.ipfsHash) {
        console.log(`  Using existing previousRegistry.ipfsHash: ${newContent.previousRegistry.ipfsHash}`);
    }

    // Re-stringify content (may have been modified with injected ipfsHash)
    // and restore chainSelector values corrupted by JSON.parse exceeding MAX_SAFE_INTEGER
    let finalContent = JSON.stringify(newContent, null, 2);
    const chainSelectorRegex = /"chainSelector":\s*(\d+)/g;
    const originalMatches = [...originalContent.matchAll(chainSelectorRegex)];
    let matchIndex = 0;
    finalContent = finalContent.replace(chainSelectorRegex, () => {
        const originalValue = originalMatches[matchIndex++]?.[1];
        return originalValue ? `"chainSelector": ${originalValue}` : `"chainSelector": 0`;
    });

    // Use JSON upload API, since registry files are JSON documents.
    // Set the visible file name and metadata via the chainable helpers.
    // Include version in keyvalues for future lookups
    const keyvalues = {
        env: inferredEnv,
        sha: githubSha,
    };
    if (version) {
        keyvalues.version = version;
    }

    // Upload as blob to preserve the exact content (including large numbers)
    const blob = new Blob([finalContent], { type: "application/json" });
    const file = new File([blob], `${name}.json`, { type: "application/json" });

    const upload = await pinata.upload.public
        .file(file)
        .name(name)
        .keyvalues(keyvalues);

    console.log(`  Pinned with version: ${version || "unknown"}`);

    return { cid: upload.cid, changed: true, version: version };
}

/**
 * Updates the previousRegistry.ipfsHash in a local registry file without pinning.
 * 
 * @param {string} filePath - Path to the registry JSON file
 * @returns {Promise<{updated: boolean, cid: string|null}>} Update result
 */
async function updatePreviousRegistry(filePath) {
    if (!existsSync(filePath)) {
        throw new Error(`File not found: ${filePath}`);
    }

    // Read original content as text to preserve large numbers like chainSelector
    const originalContent = readFileSync(filePath, "utf8");
    const registry = JSON.parse(originalContent);

    // Determine environment from registry
    const env = registry.network || "testnet";

    // Check if previousRegistry exists and needs updating
    if (!registry.previousRegistry) {
        console.log(`  No previousRegistry field found in ${filePath}`);
        return { updated: false, cid: null };
    }

    if (registry.previousRegistry.ipfsHash) {
        console.log(`  previousRegistry.ipfsHash already set: ${registry.previousRegistry.ipfsHash}`);
        return { updated: false, cid: registry.previousRegistry.ipfsHash };
    }

    // Resolve CID: try DNS first, fall back to Pinata
    console.log(`  Resolving previous ${env} registry CID via DNS...`);
    let cid = await resolveLiveCid(env);
    if (cid) {
        console.log(`  ✓ Resolved via DNS: ${cid}`);
    } else if (pinata) {
        console.log(`  DNS lookup failed, falling back to Pinata...`);
        const previousRegistryInfo = await findPreviousRegistryCid(env);
        cid = previousRegistryInfo?.cid || null;
    }

    if (!cid) {
        console.log(`  ⚠ Could not resolve previous registry CID for ${env}`);
        return { updated: false, cid: null };
    }

    // Update the registry
    registry.previousRegistry.ipfsHash = cid;

    // Stringify and restore chainSelector values (preserve large numbers)
    let stringified = JSON.stringify(registry, null, 2);

    // Restore chainSelector values from original (corrupted by JSON.parse exceeding MAX_SAFE_INTEGER)
    const chainSelectorRegex = /"chainSelector":\s*(\d+)/g;
    const originalMatches = [...originalContent.matchAll(chainSelectorRegex)];
    let matchIndex = 0;
    stringified = stringified.replace(chainSelectorRegex, () => {
        const originalValue = originalMatches[matchIndex++]?.[1];
        return originalValue ? `"chainSelector": ${originalValue}` : `"chainSelector": 0`;
    });

    // Write back to file
    writeFileSync(filePath, stringified, "utf8");
    console.log(`  ✓ Updated previousRegistry.ipfsHash to ${cid}`);

    return { updated: true, cid };
}

async function writeStepSummary(results) {
    try {
        const summary = core.summary.addHeading("Contract Registry IPFS");

        if (results.mainnet?.changed && results.mainnet?.cid) {
            summary.addHeading("Mainnet Registry", 3);
            summary.addRaw(`- Version: \`${results.mainnet.version || "unknown"}\`\n`);
            summary.addRaw(`- CID: \`${results.mainnet.cid}\`\n`);
            summary.addLink(
                "View on IPFS",
                `https://gateway.pinata.cloud/ipfs/${results.mainnet.cid}`
            );
            summary.addSeparator();
        }

        if (results.testnet?.changed && results.testnet?.cid) {
            summary.addHeading("Testnet Registry", 3);
            summary.addRaw(`- Version: \`${results.testnet.version || "unknown"}\`\n`);
            summary.addRaw(`- CID: \`${results.testnet.cid}\`\n`);
            summary.addLink(
                "View on IPFS",
                `https://gateway.pinata.cloud/ipfs/${results.testnet.cid}`
            );
            summary.addSeparator();
        }

        if (!results.mainnet?.changed && !results.testnet?.changed) {
            summary.addRaw("No registries were pinned (no changes detected).");
        }

        await summary.write();
        console.log("Step summary written successfully");
    } catch (error) {
        // If @actions/core is not available (e.g., running locally), fall back to console
        console.warn(`Could not write step summary: ${error.message}`);
        console.warn("This is normal if running outside of GitHub Actions");
    }
}

async function main() {
    const results = {};

    try {
        // Auto-detect which registry files exist
        const mainnetPath = join(process.cwd(), "registry", "registry-mainnet.json");
        const testnetPath = join(process.cwd(), "registry", "registry-testnet.json");

        const mainnetExists = existsSync(mainnetPath);
        const testnetExists = existsSync(testnetPath);

        if (!mainnetExists && !testnetExists) {
            console.log("No registry files found");
            if (updatePrevious) {
                console.log("Nothing to update");
            } else {
                console.log("Skipping IPFS pin");
                const emptyResults = { mainnet: { cid: null, changed: false }, testnet: { cid: null, changed: false } };
                writeStepSummary(emptyResults);
                console.log(JSON.stringify(emptyResults));
            }
            return;
        }

        // If --update-previous flag is set, only update local files without pinning
        if (updatePrevious) {
            if (!pinataJwt) {
                console.error("Error: PINATA_JWT environment variable is required for --update-previous");
                console.error("See: https://docs.pinata.cloud/frameworks/node-js");
                process.exit(1);
            }

            console.log("\n=== Updating previousRegistry.ipfsHash in local files ===\n");

            if (mainnetExists) {
                const mainnetResult = await updatePreviousRegistry(mainnetPath);
                results.mainnet = { cid: mainnetResult.cid, changed: mainnetResult.updated };
            }

            if (testnetExists) {
                const testnetResult = await updatePreviousRegistry(testnetPath);
                results.testnet = { cid: testnetResult.cid, changed: testnetResult.updated };
            }

            console.log("\n✓ Update complete");
            console.log(JSON.stringify(results));
            return;
        }

        // Normal pinning flow
        // Process mainnet if file exists
        if (mainnetExists) {
            const mainnetContent = JSON.parse(readFileSync(mainnetPath, "utf8"));
            const mainnetVersion = mainnetContent.version || mainnetContent.deploymentInfo?.gitCommit || "unknown";
            const name = `registry-mainnet-${mainnetVersion}`;
            const existingUrl = "https://registry.centrifuge.io";
            results.mainnet = await pinFile(mainnetPath, name, existingUrl);
            if (results.mainnet.changed && results.mainnet.cid) {
                console.log(`Mainnet CID: ${results.mainnet.cid}`);
            }
        }

        // Process testnet if file exists
        if (testnetExists) {
            const testnetContent = JSON.parse(readFileSync(testnetPath, "utf8"));
            const testnetVersion = testnetContent.version || testnetContent.deploymentInfo?.gitCommit || "unknown";
            const name = `registry-testnet-${testnetVersion}`;
            const existingUrl = "https://registry.testnet.centrifuge.io";
            results.testnet = await pinFile(testnetPath, name, existingUrl);
            if (results.testnet.changed && results.testnet.cid) {
                console.log(`Testnet CID: ${results.testnet.cid}`);
            }
        }

        // Write GitHub Actions step summary
        await writeStepSummary(results);

        // Output JSON for workflow to parse (for issue creation)
        console.log(JSON.stringify(results));
    } catch (error) {
        console.error(`Error: ${error.message}`);
        if (error.response) {
            console.error(`API response:`, error.response.data);
        }
        process.exit(1);
    }
}

main();

