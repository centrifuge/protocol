#!/usr/bin/env node
/**
 * @fileoverview Validates a generated registry JSON against indexer hard requirements.
 *
 * Runs after abi-registry.js to catch missing or malformed data that would
 * break the Ponder/indexer pipeline. Produces a structured JSON report
 * (errors + warnings + summary) written to a sidecar file for the PR comment step.
 *
 * Hard requirements (errors — break the indexer):
 *   - version: must be a non-empty string
 *   - previousRegistry.ipfsHash: must be non-null when a live registry exists for that network
 *   - chains.<chainId>.deployment.startBlock: must be a number (large gap vs env contract
 *     `blockNumber` is rejected by validate-env-schema.js before abi-registry runs)
 *   - chains.<chainId>.contracts.<name>.address: non-empty string for **active** contracts
 *   - chains.<chainId>.contracts.<name>.blockNumber: must be a number for active contracts
 *   - abis: every **active** contract must have matching ABI entries (artifact basenames via
 *     {@link artifactNamesForContractKey} in `utils/abi-cache.js` — same rules as `packAbis`)
 *
 * Deprecated delta rows (`address: null`) skip address/blockNumber/ABI checks.
 *
 * Soft requirements (warnings — shown but don't fail CI):
 *   - zero chains in a delta registry
 *
 * Usage:
 *   node script/registry/validate-registry.js registry/registry-mainnet.json
 *   node script/registry/validate-registry.js registry/registry-testnet.json
 *
 * Environment Variables:
 *   SKIP_LIVE_REGISTRY_CHECK=1  Skip fetching the live registry URL (for offline/local use)
 *
 * Output:
 *   - Structured report to stdout (JSON)
 *   - Sidecar file: <input>.validation.json (same directory as input)
 *   - Exit code: 1 if any errors, 0 if only warnings or clean
 */

import { readFileSync, writeFileSync } from "fs";
import { artifactNamesForContractKey } from "./utils/abi-cache.js";

const REGISTRY_URLS = {
    mainnet: "https://registry.centrifuge.io",
    testnet: "https://registry.testnet.centrifuge.io",
};

const skipLiveCheck = process.env.SKIP_LIVE_REGISTRY_CHECK === "1";

async function fetchLiveRegistry(environment) {
    if (skipLiveCheck) {
        console.log("  Skipping live registry check (SKIP_LIVE_REGISTRY_CHECK=1)");
        return null;
    }

    const url = REGISTRY_URLS[environment];
    if (!url) return null;

    try {
        console.log(`  Fetching live registry from ${url}...`);
        const response = await fetch(url);
        if (!response.ok) {
            console.log(`  Live registry returned ${response.status} — treating as no existing registry`);
            return null;
        }
        const data = await response.json();
        if (data && typeof data.version === "string") {
            console.log(`  Live registry found: version ${data.version}`);
            return data;
        }
        console.log("  Live registry response is not a valid registry (no version field)");
        return null;
    } catch (err) {
        console.warn(`  Could not fetch live registry: ${err.message}`);
        return null;
    }
}

async function validate(registryPath) {
    const errors = [];
    const warnings = [];

    let raw;
    let registry;
    try {
        raw = readFileSync(registryPath, "utf8");
        registry = JSON.parse(raw);
    } catch (err) {
        errors.push({ path: "(file)", message: `Cannot read/parse registry: ${err.message}` });
        return { errors, warnings, summary: {} };
    }

    // --- version ---
    if (!registry.version || typeof registry.version !== "string") {
        errors.push({
            path: "version",
            message: `Must be a non-empty string, got ${JSON.stringify(registry.version)}`,
        });
    }

    // --- previousRegistry.ipfsHash ---
    const liveRegistry = await fetchLiveRegistry(registry.network);
    if (liveRegistry) {
        if (!registry.previousRegistry?.ipfsHash) {
            errors.push({
                path: "previousRegistry.ipfsHash",
                message: `A live registry exists (version ${liveRegistry.version}) but this registry has no previousRegistry.ipfsHash — it would be an orphan in the linked list`,
            });
        }
    }
    // --- chains ---
    const chains = registry.chains || {};
    const chainIds = Object.keys(chains);

    if (chainIds.length === 0) {
        warnings.push({ path: "chains", message: "Delta registry has zero chains — nothing changed?" });
    }

    /** Artifact basenames required in `abis`, aligned with `abi-registry.js` `packAbis`. */
    const allContractNames = new Set();
    let totalContracts = 0;

    for (const chainId of chainIds) {
        const chain = chains[chainId];

        // deployment.startBlock
        const startBlock = chain.deployment?.startBlock;
        if (startBlock == null) {
            errors.push({ path: `chains.${chainId}.deployment.startBlock`, message: "Required by indexer, got null/undefined" });
        } else if (typeof startBlock !== "number") {
            errors.push({ path: `chains.${chainId}.deployment.startBlock`, message: `Must be a number, got ${typeof startBlock}: ${JSON.stringify(startBlock)}` });
        }

        // contracts
        const contracts = chain.contracts || {};
        for (const [name, contract] of Object.entries(contracts)) {
            totalContracts++;

            // Deprecation tombstone: no address / blockNumber / ABI requirements in deltas
            if (contract && typeof contract === "object" && contract.address === null) {
                continue;
            }

            for (const artifact of artifactNamesForContractKey(name)) {
                allContractNames.add(artifact);
            }

            // address
            if (!contract.address || typeof contract.address !== "string") {
                errors.push({ path: `chains.${chainId}.contracts.${name}.address`, message: `Must be a non-empty string, got ${JSON.stringify(contract.address)}` });
            }

            // blockNumber
            if (contract.blockNumber == null) {
                errors.push({ path: `chains.${chainId}.contracts.${name}.blockNumber`, message: "Required by indexer, got null/undefined" });
            } else if (typeof contract.blockNumber !== "number") {
                errors.push({ path: `chains.${chainId}.contracts.${name}.blockNumber`, message: `Must be a number, got ${typeof contract.blockNumber}: ${JSON.stringify(contract.blockNumber)}` });
            }
        }
    }

    // --- abis completeness (active contracts only) ---
    const abis = registry.abis || {};
    const abiNames = new Set(Object.keys(abis));

    for (const needed of allContractNames) {
        if (!abiNames.has(needed)) {
            errors.push({ path: `abis.${needed}`, message: `Missing ABI — active contract in chains but no ABI entry` });
        }
    }

    const summary = {
        chains: chainIds.length,
        contracts: totalContracts,
        abis: abiNames.size,
        errors: errors.length,
        warnings: warnings.length,
        // publishable: true only when the registry passes all hard requirements AND contains
        // actual contract changes (non-empty chains). Used by CI to decide whether to pin and
        // update Cloudflare automatically on push to main.
        publishable: errors.length === 0 && chainIds.length > 0,
    };

    return { errors, warnings, summary };
}

async function main() {
    const registryPath = process.argv[2];
    if (!registryPath) {
        console.error("Usage: node validate-registry.js <path-to-registry.json>");
        process.exit(1);
    }

    console.log(`Validating registry: ${registryPath}`);
    const report = await validate(registryPath);

    // Write sidecar file for the PR comment step
    const sidecarPath = registryPath.replace(/\.json$/, ".validation.json");
    writeFileSync(sidecarPath, JSON.stringify(report, null, 2));
    console.log(`\nValidation report written to ${sidecarPath}`);

    // Print summary
    console.log(`\n=== Validation Summary ===`);
    console.log(`  Chains: ${report.summary.chains}`);
    console.log(`  Contracts: ${report.summary.contracts}`);
    console.log(`  ABIs: ${report.summary.abis}`);
    console.log(`  Errors: ${report.summary.errors}`);
    console.log(`  Warnings: ${report.summary.warnings}`);

    if (report.errors.length > 0) {
        console.error(`\n✗ ${report.errors.length} error(s) — these will break the indexer:\n`);
        for (const err of report.errors) {
            console.error(`  [ERROR] ${err.path}: ${err.message}`);
        }
    }

    if (report.warnings.length > 0) {
        console.warn(`\n⚠ ${report.warnings.length} warning(s):\n`);
        for (const warn of report.warnings) {
            console.warn(`  [WARN]  ${warn.path}: ${warn.message}`);
        }
    }

    if (report.errors.length === 0) {
        console.log("\n✓ Registry passes all indexer hard requirements");
    }

    // Print the full JSON report to stdout for programmatic consumption
    console.log("\n" + JSON.stringify(report));

    process.exit(report.errors.length > 0 ? 1 : 0);
}

main();
