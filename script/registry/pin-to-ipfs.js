#!/usr/bin/env node
/**
 * @fileoverview Pins delta registry files to IPFS using Pinata SDK.
 * 
 * This script handles the pinning of delta registries and manages the version chain:
 * 1. Queries Pinata for the previous registry's CID using env metadata
 * 2. Injects the CID into the previousRegistry.ipfsHash field
 * 3. Pins the updated registry with version metadata for future lookups
 * 
 * Usage:
 *   node script/registry/pin-to-ipfs.js
 * 
 * Environment variables:
 *   PINATA_JWT - Pinata JWT token (required)
 *   PINATA_GATEWAY - Pinata gateway domain (optional, defaults to "gateway.pinata.cloud")
 *   GITHUB_SHA - Git commit SHA for naming (optional, defaults to "latest")
 *   GITHUB_STEP_SUMMARY - Path to GitHub Actions step summary file (optional)
 * 
 * Output: Prints JSON with IPFS hashes and change status to stdout:
 *   {"mainnet": {"cid": "Qm...", "changed": true}, "testnet": {"cid": "Qm...", "changed": true}}
 * 
 * Also writes GitHub Actions step summary if GITHUB_STEP_SUMMARY is set.
 */

import { PinataSDK } from "pinata";
import { readFileSync, existsSync } from "fs";
import { join } from "path";
import * as core from "@actions/core";

const pinataJwt = process.env.PINATA_JWT;
const githubSha = process.env.GITHUB_SHA || "latest";

// Initialize Pinata SDK
// Gateway is optional (mainly for fetching), but SDK may require it
const pinataGateway = process.env.PINATA_GATEWAY || "gateway.pinata.cloud";

if (!pinataJwt) {
    console.error("Error: PINATA_JWT environment variable is required");
    console.error("See: https://docs.pinata.cloud/frameworks/node-js");
    process.exit(1);
}

const pinata = new PinataSDK({
    pinataJwt: pinataJwt,
    pinataGateway: pinataGateway,
});

/**
 * Queries Pinata for the most recently pinned registry matching the environment.
 * Uses metadata filtering to find registries by env (mainnet/testnet).
 * 
 * @param {string} env - Environment to search for ("mainnet" or "testnet")
 * @returns {Promise<{cid: string, version: string}|null>} Previous registry info or null
 */
async function findPreviousRegistryCid(env) {
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
    const existingStr = JSON.stringify(existing, Object.keys(existing).sort());
    const newStr = JSON.stringify(newContent, Object.keys(newContent).sort());

    return existingStr !== newStr;
}

async function pinFile(filePath, name, existingUrl) {
    if (!existsSync(filePath)) {
        throw new Error(`File not found: ${filePath}`);
    }

    const newContent = JSON.parse(readFileSync(filePath, "utf8"));

    // Fetch and compare with existing registry
    const existing = existingUrl ? await fetchExistingRegistry(existingUrl) : null;
    const changed = compareRegistries(existing, newContent);

    if (!changed) {
        console.log(`Registry unchanged, skipping pin for ${name}`);
        return { cid: null, changed: false };
    }

    console.log(`Registry changed, pinning ${name}...`);

    // Determine environment from URL or name
    const inferredEnv =
        existingUrl?.includes("testnet") || name.toLowerCase().includes("testnet")
            ? "testnet"
            : "mainnet";

    // Extract version from the registry content
    const version = newContent.version || newContent.deploymentInfo?.gitCommit || null;

    // Query Pinata for the previous registry's CID
    const previousRegistryInfo = await findPreviousRegistryCid(inferredEnv);

    // Inject the previous registry's CID into the content before pinning
    if (newContent.previousRegistry && previousRegistryInfo?.cid) {
        newContent.previousRegistry.ipfsHash = previousRegistryInfo.cid;
        console.log(`  Injected previousRegistry.ipfsHash: ${previousRegistryInfo.cid}`);
    }

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

    const upload = await pinata.upload.public
        .json(newContent)
        .name(name)
        .keyvalues(keyvalues);

    console.log(`  Pinned with version: ${version || "unknown"}`);

    return { cid: upload.cid, changed: true, version: version };
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
            console.log("No registry files found, skipping IPFS pin");
            const emptyResults = { mainnet: { cid: null, changed: false }, testnet: { cid: null, changed: false } };
            writeStepSummary(emptyResults);
            console.log(JSON.stringify(emptyResults));
            return;
        }

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
        console.error(`Error pinning to IPFS: ${error.message}`);
        if (error.response) {
            console.error(`API response:`, error.response.data);
        }
        process.exit(1);
    }
}

main();

