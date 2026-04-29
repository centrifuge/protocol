#!/usr/bin/env node
/**
 * @fileoverview Validates the schema of all env/*.json files.
 *
 * Fast-fail gate that runs before registry generation to catch structural
 * issues (field renames, missing required keys, type mismatches) that would
 * cause abi-registry.js to silently skip chains or crash.
 *
 * When any contract has a numeric `blockNumber`, requires `deploymentInfo.*.startBlock`
 * (indexers use it for chain-level block polling). Validates that startBlock is not
 * wildly earlier than the earliest contract deployment block (gap threshold below).
 * The generated registry copies this from env (`abi-registry.js`); no duplicate check
 * in validate-registry.js.
 *
 * Usage:
 *   node script/registry/validate-env-schema.js
 *
 * Exit code: 0 if all files pass, 1 if any file has errors.
 */

import { readdirSync, readFileSync } from "fs";
import { basename, join } from "path";

const envDir = join(process.cwd(), "env");

const VALID_ENVIRONMENTS = new Set(["mainnet", "testnet"]);
const KNOWN_TOP_LEVEL_KEYS = new Set([
    "network",
    "adapters",
    "contracts",
    "deploymentInfo",
]);
const ADDRESS_REGEX = /^0x[0-9a-fA-F]{40}$/;

/** Same scan order as abi-registry.js `getDeploymentStartBlock`. */
function getDeploymentStartBlockFromEnv(chain) {
    const info = chain.deploymentInfo;
    if (!info || typeof info !== "object") return null;
    for (const value of Object.values(info)) {
        if (value && typeof value === "object" && typeof value.startBlock === "number") {
            return value.startBlock;
        }
    }
    return null;
}

function minActiveContractBlockNumber(contracts) {
    if (!contracts || typeof contracts !== "object") return null;
    let min = null;
    for (const contract of Object.values(contracts)) {
        if (!contract || typeof contract !== "object") continue;
        if (contract.address === null) continue;
        if (typeof contract.blockNumber !== "number") continue;
        if (min === null || contract.blockNumber < min) min = contract.blockNumber;
    }
    return min;
}

function startBlockGapErrorThreshold(minContractBlock) {
    return Math.max(5_000_000, Math.floor(minContractBlock * 0.005));
}

/** @returns {string[]} human-readable errors (empty if ok) */
function startBlockGapErrors(envLabel, startBlock, contracts) {
    const minBlock = minActiveContractBlockNumber(contracts);
    if (minBlock == null || typeof startBlock !== "number" || !Number.isFinite(startBlock)) {
        return [];
    }
    const gap = minBlock - startBlock;
    const threshold = startBlockGapErrorThreshold(minBlock);
    if (gap < threshold) return [];
    return [
        `${envLabel} deploymentInfo.startBlock: startBlock (${startBlock}) lies far before the earliest active contract deployment (min blockNumber ${minBlock}, gap ${gap} blocks ≥ threshold ${threshold}). ` +
            `Chain-level block listeners use deployment.startBlock (e.g. hourly snapshots); align it when merging deployment metadata (deploymentStartBlock / broadcast fallback).`,
    ];
}

function hasAnyNumericContractBlockNumber(chain) {
    if (!chain.contracts || typeof chain.contracts !== "object") return false;
    for (const value of Object.values(chain.contracts)) {
        if (typeof value === "object" && value !== null && typeof value.blockNumber === "number") {
            return true;
        }
    }
    return false;
}

/**
 * Validates a single env file. Returns an array of error strings (empty = valid).
 */
function validateEnvFile(filePath) {
    const errors = [];
    let raw;
    let chain;

    try {
        raw = readFileSync(filePath, "utf8");
    } catch (err) {
        errors.push(`Could not read file: ${err.message}`);
        return errors;
    }

    try {
        chain = JSON.parse(raw);
    } catch (err) {
        errors.push(`Invalid JSON: ${err.message}`);
        return errors;
    }

    if (typeof chain !== "object" || chain === null || Array.isArray(chain)) {
        errors.push("Root must be a JSON object");
        return errors;
    }

    for (const key of Object.keys(chain)) {
        if (!KNOWN_TOP_LEVEL_KEYS.has(key)) {
            errors.push(
                `Unknown top-level key "${key}". ` +
                `Expected one of: ${Array.from(KNOWN_TOP_LEVEL_KEYS).join(", ")}. ` +
                `If this is intentional, update validate-env-schema.js.`
            );
        }
    }

    // --- network (required) ---
    if (!chain.network) {
        errors.push('Missing required key "network"');
    } else if (typeof chain.network !== "object" || Array.isArray(chain.network)) {
        errors.push('"network" must be an object');
    } else {
        if (chain.network.chainId == null) {
            errors.push('"network.chainId" is required');
        } else if (typeof chain.network.chainId !== "number" || !Number.isInteger(chain.network.chainId)) {
            errors.push(`"network.chainId" must be an integer, got ${typeof chain.network.chainId}: ${chain.network.chainId}`);
        }

        if (chain.network.environment != null && !VALID_ENVIRONMENTS.has(chain.network.environment)) {
            errors.push(
                `"network.environment" must be "mainnet" or "testnet", got "${chain.network.environment}"`
            );
        }
    }

    // --- contracts (optional but validated if present) ---
    if (chain.contracts != null) {
        if (typeof chain.contracts !== "object" || Array.isArray(chain.contracts)) {
            errors.push('"contracts" must be an object');
        } else {
            for (const [name, value] of Object.entries(chain.contracts)) {
                if (typeof value === "string") {
                    if (!ADDRESS_REGEX.test(value)) {
                        errors.push(`contracts.${name}: invalid address format "${value}"`);
                    }
                } else if (typeof value === "object" && value !== null) {
                    const addr = value.address;
                    if (!addr) {
                        errors.push(`contracts.${name}: missing "address" field`);
                    } else if (!ADDRESS_REGEX.test(addr)) {
                        errors.push(`contracts.${name}: invalid address format "${addr}"`);
                    }
                    if (value.blockNumber != null && typeof value.blockNumber !== "number") {
                        errors.push(`contracts.${name}.blockNumber: must be a number, got ${typeof value.blockNumber}`);
                    }
                } else {
                    errors.push(`contracts.${name}: must be an address string or an object with "address", got ${typeof value}`);
                }
            }
        }
    }

    // --- deploymentInfo (optional but validated if present) ---
    if (chain.deploymentInfo != null) {
        if (typeof chain.deploymentInfo !== "object" || Array.isArray(chain.deploymentInfo)) {
            errors.push('"deploymentInfo" must be an object');
        } else {
            for (const [key, value] of Object.entries(chain.deploymentInfo)) {
                if (typeof value !== "object" || value === null) {
                    errors.push(`deploymentInfo.${key}: must be an object`);
                } else if (value.startBlock != null && typeof value.startBlock !== "number") {
                    errors.push(`deploymentInfo.${key}.startBlock: must be a number`);
                }
            }
        }
    }

    const envLabel = basename(filePath);
    if (hasAnyNumericContractBlockNumber(chain)) {
        const startBlock = getDeploymentStartBlockFromEnv(chain);
        if (startBlock == null) {
            errors.push(
                `${envLabel}: missing deploymentInfo.*.startBlock — required when any contract has blockNumber ` +
                    `(indexers use it for chain-level block listeners, e.g. hourly snapshots; see script/registry/README.md)`
            );
        } else {
            for (const msg of startBlockGapErrors(envLabel, startBlock, chain.contracts || {})) {
                errors.push(msg);
            }
        }
    }

    // --- adapters (optional but validated if present) ---
    if (chain.adapters != null) {
        if (typeof chain.adapters !== "object" || Array.isArray(chain.adapters)) {
            errors.push('"adapters" must be an object');
        }
    }

    return errors;
}

function main() {
    let files;
    try {
        files = readdirSync(envDir).filter((f) => f.endsWith(".json"));
    } catch (err) {
        console.error(`Could not read env directory: ${err.message}`);
        process.exit(1);
    }

    if (files.length === 0) {
        console.warn("No env/*.json files found");
        process.exit(0);
    }

    let totalErrors = 0;
    const results = [];

    for (const file of files) {
        const filePath = join(envDir, file);
        const errors = validateEnvFile(filePath);
        if (errors.length > 0) {
            totalErrors += errors.length;
            results.push({ file, errors });
        }
    }

    if (totalErrors === 0) {
        console.log(`✓ All ${files.length} env files pass schema validation`);
        process.exit(0);
    }

    console.error(`\n✗ ${totalErrors} error(s) in ${results.length} file(s):\n`);
    for (const { file, errors } of results) {
        console.error(`  env/${file}:`);
        for (const err of errors) {
            console.error(`    - ${err}`);
        }
        console.error("");
    }
    process.exit(1);
}

main();
