#!/usr/bin/env node
/**
 * Fails if any env contract is missing `version` or if `version` does not resolve to a git tag.
 * Run after `git fetch --tags` in CI (see registry.yml).
 *
 * Usage (repo root):
 *   node script/registry/utils/validate-env-contract-version-tags.js
 */

import { readdirSync, readFileSync } from "fs";
import { join } from "path";
import { resolveVersionTag, versionTagCandidates } from "./tag-resolution.js";

const envDir = join(process.cwd(), "env");
const errors = [];

for (const file of readdirSync(envDir).filter((f) => f.endsWith(".json"))) {
    const path = join(envDir, file);
    let chain;
    try {
        chain = JSON.parse(readFileSync(path, "utf8"));
    } catch (e) {
        errors.push(`${file}: invalid JSON (${e.message})`);
        continue;
    }

    const chainId = chain.network?.chainId;
    const environment = chain.network?.environment;
    if (chainId === 31337) continue;
    if (environment !== "mainnet" && environment !== "testnet") continue;

    const contracts = chain.contracts || {};
    for (const [name, data] of Object.entries(contracts)) {
        if (typeof data === "string") {
            errors.push(`${file} chain ${chainId} (${environment}): "${name}" is a bare address string; add an object with address + version`);
            continue;
        }
        if (!data || typeof data !== "object") {
            errors.push(`${file} chain ${chainId}: "${name}" has invalid contract entry`);
            continue;
        }
        const version = data.version;
        if (!version || typeof version !== "string") {
            errors.push(
                `${file} chain ${chainId} (${environment}): contract "${name}" is missing a non-empty "version" field (required for ABI tag resolution)`
            );
            continue;
        }
        try {
            resolveVersionTag(version, { fetchTagsOnMiss: true });
        } catch (e) {
            const tried = versionTagCandidates(version).join(", ");
            errors.push(
                `${file} chain ${chainId} (${environment}): contract "${name}" version "${version}" → no git tag. Tried: ${tried}. (${e.message})`
            );
        }
    }
}

if (errors.length > 0) {
    console.error("validate-env-contract-version-tags: FAILED\n");
    for (const line of errors) {
        console.error(`  - ${line}`);
    }
    console.error(`\nTotal: ${errors.length} error(s). Push a matching release tag (e.g. v3.1.0) or fix env contract versions.`);
    process.exit(1);
}

console.log("validate-env-contract-version-tags: OK (all mainnet/testnet contracts have resolvable version tags)");
