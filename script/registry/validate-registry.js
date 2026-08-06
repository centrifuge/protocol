#!/usr/bin/env node
/**
 * @fileoverview Validates a generated registry JSON against indexer hard requirements.
 *
 * Runs after abi-registry.js to catch missing or malformed data that would
 * break the Ponder/indexer pipeline. Produces a structured JSON report
 * (errors + warnings + summary) written to a sidecar file for the PR comment step.
 *
 * Hard requirements (errors — break the indexer):
 *   - version: must be a non-empty string **OR** null when this is a patch layer (i.e.
 *     `previousRegistry.ipfsHash` is set). Null patches are merged into their predecessor by
 *     `api-v3/scripts/fetch-registry.mjs::mergeNullVersionPatchesIntoPredecessors`, so the
 *     oldest registry in the chain (no `previousRegistry`) must still have a string version.
 *   - previousRegistry.ipfsHash: must be non-null when a live registry exists for that network
 *   - chains.<chainId>.deployment.startBlock: must be a number (large gap vs env contract
 *     `blockNumber` is rejected by validate-env-schema.js before abi-registry runs)
 *   - chains.<chainId>.contracts.<name>.address: non-empty string for **active** contracts
 *   - chains.<chainId>.contracts.<name>.blockNumber: must be a number for active contracts,
 *     unless `chains.<chainId>.deployment.startBlock` is set (api-v3 falls back for version
 *     boundaries); then a **warning** only — prefer filling blockNumber when explorers allow it
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
import { fetchLiveRegistry as fetchLiveRegistryDocument } from "./utils/registry-fetch.js";
import { collectRegistryChain } from "./utils/registry-chain.js";
import { checkDeltaInvariants, loadEnvChains } from "./utils/registry-invariants.js";

const skipLiveCheck = process.env.SKIP_LIVE_REGISTRY_CHECK === "1";

async function fetchLiveRegistry(environment) {
    if (skipLiveCheck) {
        console.log("  Skipping live registry check (SKIP_LIVE_REGISTRY_CHECK=1)");
        return null;
    }

    const data = await fetchLiveRegistryDocument(environment, { log: console.log });
    if (!data || typeof data !== "object" || !data.chains) {
        console.log("  No usable live registry — treating as no existing registry");
        return null;
    }

    // A live tip may legitimately be a null-version patch layer, so presence is keyed on `chains`
    // rather than on `version`. Reporting such a tip as "no registry" would waive the orphan check
    // below and let a delta be published with no previousRegistry pointer.
    console.log(`  Live registry found: version ${data.version ?? "null (patch layer)"}`);
    return data;
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

    // --- mode classification --- (for the sidecar / PR comment; also informs the version rule)
    const hasPreviousRegistryHash =
        registry.previousRegistry &&
        typeof registry.previousRegistry === "object" &&
        typeof registry.previousRegistry.ipfsHash === "string" &&
        registry.previousRegistry.ipfsHash.length > 0;
    const versionIsString =
        typeof registry.version === "string" && registry.version.length > 0;
    let mode;
    if (registry.previousRegistry == null) {
        mode = "full";
    } else if (registry.version === null && hasPreviousRegistryHash) {
        mode = "patch";
    } else {
        mode = "delta";
    }

    // --- version ---
    if (mode === "patch") {
        if (registry.version !== null) {
            errors.push({
                path: "version",
                message: `Patch registries must have version: null, got ${JSON.stringify(registry.version)}`,
            });
        }
    } else if (!versionIsString) {
        errors.push({
            path: "version",
            message:
                mode === "full"
                    ? `Full snapshot must have a non-empty string version, got ${JSON.stringify(registry.version)}`
                    : `Delta registries must have a non-empty string version, got ${JSON.stringify(registry.version)} (use a null version only when this is a patch layer with previousRegistry.ipfsHash set)`,
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
            } else if (!/^0x[0-9a-fA-F]{40}$/.test(contract.address)) {
                errors.push({
                    path: `chains.${chainId}.contracts.${name}.address`,
                    message: `Not a 20-byte hex address: ${JSON.stringify(contract.address)}`,
                });
            }

            // blockNumber — api-v3 uses contract.blockNumber ?? chain.deployment.startBlock for
            // end-block logic; Ponder start blocks use deployment.startBlock. Allow null when the
            // chain has a numeric deployment start (e.g. CREATE3 / src-ir where creation APIs fail).
            const deploymentStart = chain.deployment?.startBlock;
            const hasDeploymentStartBlock =
                typeof deploymentStart === "number" && Number.isFinite(deploymentStart);
            if (contract.blockNumber == null) {
                if (hasDeploymentStartBlock) {
                    warnings.push({
                        path: `chains.${chainId}.contracts.${name}.blockNumber`,
                        message:
                            "Null blockNumber — allowed because chain.deployment.startBlock is set (indexer fallback); add blockNumber when creation data is available",
                    });
                } else {
                    errors.push({
                        path: `chains.${chainId}.contracts.${name}.blockNumber`,
                        message: "Required by indexer, got null/undefined (no chain.deployment.startBlock fallback)",
                    });
                }
            } else if (typeof contract.blockNumber !== "number") {
                errors.push({
                    path: `chains.${chainId}.contracts.${name}.blockNumber`,
                    message: `Must be a number, got ${typeof contract.blockNumber}: ${JSON.stringify(contract.blockNumber)}`,
                });
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

    // --- delta invariants (semantic, not structural) ---
    // Structural checks pass on a delta that re-states already-published contracts, which is how a
    // near-full snapshot shipped three times. These compare the delta to the state it extends.
    let deltaStats = null;
    if (liveRegistry && mode !== "full") {
        console.log("  Reconstructing the published chain to check delta invariants...");
        const { layers, accumulated, accumulatedAbis, complete, reason, fatal } = await collectRegistryChain(liveRegistry, {
            expectedNetwork: registry.network,
            log: console.log,
        });

        if (fatal) {
            // An unreachable layer only costs us the invariant check; a chain from the other
            // environment means this registry is being compared to the wrong world entirely.
            errors.push({ path: "(chain)", message: `Published chain is unusable: ${reason}` });
        } else if (!complete) {
            warnings.push({
                path: "(chain)",
                message: `Skipped delta invariants — could not reconstruct the published chain: ${reason}`,
            });
        } else {
            const invariants = checkDeltaInvariants({
                accumulatedChains: accumulated,
                accumulatedAbiNames: accumulatedAbis,
                deltaRegistry: registry,
                envChains: loadEnvChains(registry.network),
            });
            errors.push(...invariants.errors);
            warnings.push(...invariants.warnings);
            deltaStats = invariants.stats;
            console.log(
                `  Delta carries ${deltaStats.deltaContracts} of ` +
                `${deltaStats.accumulatedContracts} published contracts across ${layers.length} layer(s)`
            );
        }
    }

    const summary = {
        mode, // "full" | "delta" | "patch"
        chains: chainIds.length,
        contracts: totalContracts,
        abis: abiNames.size,
        ...(deltaStats ? { delta: deltaStats } : {}),
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
    if (report.summary.mode) {
        console.log(`  Mode: ${report.summary.mode}`);
    }
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
