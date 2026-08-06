/**
 * @fileoverview Semantic checks on a generated delta, beyond "is this valid JSON with the right
 * fields in it".
 *
 * The delta that oscillated between 443 and 12 contracts passed every structural check there was,
 * because a delta re-stating contracts that are already published is perfectly well-formed. What it
 * violated is a property nothing was asserting: a delta must describe *the difference* between the
 * published state and env, no more and no less.
 *
 * Two invariants pin that down, both computed against the flattened published chain:
 *
 *   1. Projection. Applying the delta to the published state must reproduce env exactly. Catches a
 *      delta that omits a real change or invents one.
 *   2. Minimality. No delta entry may restate what the published state already says. Catches the
 *      inflation directly — this is the check that fails on the original bug.
 *
 * A size heuristic warns when a delta looks like a snapshot, which is what a human noticed first.
 */

import { readFileSync, readdirSync } from "fs";
import { join } from "path";

import { artifactNamesForContractKey } from "./abi-cache.js";

/** Fraction of the accumulated state above which a delta stops looking like a delta. */
const SNAPSHOT_RATIO = 0.3;

/** Below this many contracts, a large ratio is unremarkable (early chains, small networks). */
const SNAPSHOT_FLOOR = 20;

/**
 * Artifact basenames a contract key needs that the chain has never published.
 *
 * @param {string} contractKey - env/registry contracts key, e.g. `tokenBridge`
 * @param {Set<string>|null} publishedAbiNames - ABI names present in the chain
 * @returns {string[]} Missing names; empty when coverage is complete or unknown
 */
function missingAbiNames(contractKey, publishedAbiNames) {
    if (!publishedAbiNames) return [];
    return artifactNamesForContractKey(contractKey).filter((name) => !publishedAbiNames.has(name));
}

function addressOf(entry) {
    return typeof entry === "string" ? entry : entry?.address;
}

function blockNumberOf(entry) {
    return typeof entry === "string" ? null : entry?.blockNumber;
}

/**
 * Loads the chains an environment's env files describe, keyed by chainId.
 *
 * Mirrors the generator's selection: files whose `network.environment` matches, minus the local
 * dev chain. Anything else would compare the delta against a different set of chains than produced
 * it.
 *
 * @param {string} environment - "mainnet" or "testnet"
 * @param {string} [envDir] - Directory holding env/*.json
 * @returns {Object} chainId → { contracts }
 */
export function loadEnvChains(environment, envDir = join(process.cwd(), "env")) {
    const chains = {};

    for (const file of readdirSync(envDir).filter((name) => name.endsWith(".json"))) {
        let parsed;
        try {
            parsed = JSON.parse(readFileSync(join(envDir, file), "utf8"));
        } catch {
            continue; // validate-env-schema.js is the gate for malformed env files
        }
        const chainId = parsed?.network?.chainId;
        if (parsed?.network?.environment !== environment) continue;
        if (chainId == null || chainId === 31337) continue;

        chains[String(chainId)] = { contracts: parsed.contracts || {} };
    }

    return chains;
}

function sameAddress(a, b) {
    const left = addressOf(a);
    const right = addressOf(b);
    if (left == null || right == null) return left === right;
    return left.toLowerCase() === right.toLowerCase();
}

/**
 * Whether a blockNumber env states is what the other side resolves to.
 *
 * Only judged in that direction, matching `hasContractChanged`: env is the source of truth for a
 * blockNumber it has, and a blockNumber env does not have says nothing about the published one.
 *
 * @param {Object|string} envEntry - Contract entry from env
 * @param {Object|string} otherEntry - Entry to compare against
 * @returns {boolean} True when env states no blockNumber, or both agree
 */
function blockNumberAgrees(envEntry, otherEntry) {
    const envBlock = blockNumberOf(envEntry);
    if (envBlock == null) return true;
    return String(envBlock) === String(blockNumberOf(otherEntry));
}

/**
 * Applies a delta's chains onto the accumulated published state, as an indexer would.
 */
function project(accumulatedChains, deltaChains) {
    const projected = {};

    for (const [chainId, chainData] of Object.entries(accumulatedChains || {})) {
        projected[chainId] = { ...(chainData.contracts || {}) };
    }
    for (const [chainId, chainData] of Object.entries(deltaChains || {})) {
        projected[chainId] = { ...(projected[chainId] || {}), ...(chainData.contracts || {}) };
    }

    return projected;
}

/**
 * Checks a generated delta against the state it claims to extend.
 *
 * @param {Object} params
 * @param {Object} params.accumulatedChains - Flattened published state (flattenRegistryChain output)
 * @param {Object} params.deltaRegistry - The generated registry document
 * @param {Object} params.envChains - chainId → { contracts } from env/*.json, for this environment
 * @param {Set<string>|null} [params.accumulatedAbiNames] - ABI names published anywhere in the
 *        chain (flattenRegistryAbis output). Omit to skip the ABI-coverage invariant.
 * @returns {{errors: Array<{path: string, message: string}>, warnings: Array, stats: Object}}
 */
export function checkDeltaInvariants({
    accumulatedChains,
    deltaRegistry,
    envChains,
    accumulatedAbiNames = null,
}) {
    const errors = [];
    const warnings = [];

    const deltaChains = deltaRegistry?.chains || {};
    const deltaAbiNames = new Set(Object.keys(deltaRegistry?.abis || {}));
    const projected = project(accumulatedChains, deltaChains);

    // --- 1. Projection: published state + delta must equal env ---
    for (const [chainId, envChain] of Object.entries(envChains || {})) {
        const envContracts = envChain?.contracts || {};
        const projectedContracts = projected[chainId] || {};

        for (const [name, envContract] of Object.entries(envContracts)) {
            const projectedContract = projectedContracts[name];
            if (!projectedContract || projectedContract.address === null) {
                errors.push({
                    path: `chains.${chainId}.contracts.${name}`,
                    message:
                        `Present in env but missing from the published state after applying this ` +
                        `delta — an indexer reading the chain would never see this contract`,
                });
            } else if (!sameAddress(projectedContract, envContract)) {
                errors.push({
                    path: `chains.${chainId}.contracts.${name}.address`,
                    message:
                        `Published state after this delta resolves to ` +
                        `${addressOf(projectedContract)} but env says ${addressOf(envContract)}`,
                });
            } else if (!blockNumberAgrees(envContract, projectedContract)) {
                // The address alone is not the whole entry: the indexer starts this contract's
                // listener at its blockNumber, falling back to the chain-level startBlock. A delta
                // that leaves the wrong one — or none — published is not a faithful projection of env.
                errors.push({
                    path: `chains.${chainId}.contracts.${name}.blockNumber`,
                    message:
                        `Published state after this delta resolves to blockNumber ` +
                        `${blockNumberOf(projectedContract) ?? "null"} but env says ` +
                        `${blockNumberOf(envContract)}`,
                });
            }
        }

        for (const [name, projectedContract] of Object.entries(projectedContracts)) {
            if (projectedContract?.address === null) continue; // correctly retired
            if (envContracts[name]) continue;
            errors.push({
                path: `chains.${chainId}.contracts.${name}`,
                message:
                    `Still live in the published state after this delta but absent from env — ` +
                    `it should have been tombstoned with address: null`,
            });
        }
    }

    // A chain in the delta that env does not describe at all cannot be validated against anything.
    for (const chainId of Object.keys(deltaChains)) {
        if (!envChains?.[chainId]) {
            warnings.push({
                path: `chains.${chainId}`,
                message: "Chain is in the delta but has no env file for this environment",
            });
        }
    }

    // --- 2. Minimality: no entry may restate what is already published ---
    let redundant = 0;
    for (const [chainId, chainData] of Object.entries(deltaChains)) {
        const published = accumulatedChains?.[chainId]?.contracts || {};
        for (const [name, entry] of Object.entries(chainData.contracts || {})) {
            const existing = published[name];
            if (!existing) continue;

            if (entry?.address === null) {
                // Re-tombstoning something already retired is redundant too.
                if (existing.address === null) {
                    redundant++;
                    errors.push({
                        path: `chains.${chainId}.contracts.${name}`,
                        message: "Re-tombstones a contract the published state already retired",
                    });
                }
                continue;
            }

            const addressUnchanged = sameAddress(entry, existing);
            // Mirrors hasContractChanged, so an entry the delta was right to include can never be
            // reported as redundant: a blockNumber the entry states must match the published one,
            // including when the chain carried none and this entry backfills it.
            const blockUnchanged = blockNumberAgrees(entry, existing);

            if (addressUnchanged && blockUnchanged) {
                // One legitimate reason to restate an unchanged contract: the chain never carried
                // its ABI, and this delta ships it. Allowed, but surfaced so it is not invisible.
                const healed = missingAbiNames(name, accumulatedAbiNames).filter((abiName) =>
                    deltaAbiNames.has(abiName)
                );
                if (healed.length > 0) {
                    warnings.push({
                        path: `chains.${chainId}.contracts.${name}`,
                        message:
                            `Restates the published state, but ships ${healed.join(", ")} — an ABI ` +
                            `the chain never carried. Allowed: without it the gap would be permanent`,
                    });
                    continue;
                }

                redundant++;
                errors.push({
                    path: `chains.${chainId}.contracts.${name}`,
                    message:
                        `Restates the published state (same address and blockNumber) — a delta must ` +
                        `carry only what changed. Re-emitting published contracts is what made ` +
                        `earlier publishes oscillate between near-full snapshots`,
                });
            }
        }
    }

    // --- 3. ABI coverage: every live contract must resolve to an ABI somewhere in the chain ---
    // `packAbis` can finish with "ABIs not found for: …" and still publish. Before deltas were
    // computed against the accumulated state, such a gap healed by accident on the next run; now
    // nothing re-emits an unchanged contract, so an undetected gap is permanent in the chain.
    if (accumulatedAbiNames) {
        const uncovered = new Map(); // artifact name → where it is needed
        for (const [chainId, projectedContracts] of Object.entries(projected)) {
            for (const [name, entry] of Object.entries(projectedContracts)) {
                if (entry?.address == null) continue; // retired; the ABI is not needed going forward
                for (const abiName of missingAbiNames(name, accumulatedAbiNames)) {
                    if (deltaAbiNames.has(abiName)) continue; // this delta closes it
                    if (!uncovered.has(abiName)) uncovered.set(abiName, []);
                    uncovered.get(abiName).push(`${chainId}.${name}`);
                }
            }
        }
        for (const [abiName, where] of uncovered) {
            errors.push({
                path: `abis.${abiName}`,
                message:
                    `No layer in the chain carries this ABI, and this delta does not add it, but ` +
                    `${where.length} live contract(s) need it (${where.slice(0, 3).join(", ")}` +
                    `${where.length > 3 ? ", …" : ""}). An indexer walking the chain cannot decode them`,
            });
        }
    }

    // --- 4. Size heuristic ---
    const accumulatedContracts = Object.values(accumulatedChains || {}).reduce(
        (sum, chainData) => sum + Object.keys(chainData.contracts || {}).length,
        0
    );
    const deltaContracts = Object.values(deltaChains).reduce(
        (sum, chainData) => sum + Object.keys(chainData.contracts || {}).length,
        0
    );
    const deltaRatio = accumulatedContracts > 0 ? deltaContracts / accumulatedContracts : null;

    if (
        accumulatedContracts > 0 &&
        deltaContracts > SNAPSHOT_FLOOR &&
        deltaRatio > SNAPSHOT_RATIO
    ) {
        warnings.push({
            path: "chains",
            message:
                `Delta carries ${deltaContracts} of ${accumulatedContracts} published contracts ` +
                `(${Math.round(deltaRatio * 100)}%) — large for a delta. Expected for a broad ` +
                `redeploy or a backlog of tombstones; otherwise check what it is comparing against`,
        });
    }

    return {
        errors,
        warnings,
        stats: {
            accumulatedContracts,
            deltaContracts,
            deltaRatio: deltaRatio === null ? null : Number(deltaRatio.toFixed(4)),
            redundantContracts: redundant,
        },
    };
}
