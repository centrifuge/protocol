/**
 * Per-tag Forge ABI cache (protocol repo root as `cwd`).
 *
 * **On-disk layout** (see `script/registry/README.md` → “ABI cache layout”):
 * - `cache/abi-registry/<git-tag>/out/` — persisted Forge `out/` tree (Foundry JSON artifacts).
 * - `cache/abi-registry/worktrees/<git-tag>/` — ephemeral; created during `ensureAbiCache`, deleted after copy.
 *
 * **Flow:** `ensureAbiCache(tag)` → cache hit if `<tag>/out` exists; else worktree + submodule init +
 * `forge build --skip test` → copy `out/` → remove worktree.
 *
 * **Consumers:** `abi-registry.js` (pack ABIs), `build-abi-cache.js` (CLI warm), `validate-registry.js`,
 * or import `getCachedOutDir`, `findAbiInOutput`, `resolveArtifactName`, `artifactNamesForContractKey`.
 *
 * @module
 */

import {
    readFileSync,
    readdirSync,
    mkdirSync,
    existsSync,
    cpSync,
    rmSync,
} from "fs";
import { join } from "path";
import { execSync } from "child_process";
import { resolveVersionTag } from "./tag-resolution.js";

/**
 * Capitalized env/registry contract key → Forge artifact JSON basename (without `.json`).
 *
 * Registry `chains.*.contracts` keys are camelCase (e.g. `fullRestrictionsHook`); the first
 * letter is uppercased for lookup here. When that string does not match the Solidity contract
 * / artifact name, map it here so `packAbis`, `validate-registry.js`, and any other consumer
 * stay aligned without duplicating tables.
 */
export const ABI_NAME_ALIASES = {
    Token: "ShareToken",
    NavManager: "NAVManager",
    FreezeOnlyHook: "FreezeOnly",
    FullRestrictionsHook: "FullRestrictions",
    FreelyTransferableHook: "FreelyTransferable",
    RedemptionRestrictionsHook: "RedemptionRestrictions",
};

/**
 * @param {string} [cwd=process.cwd()]
 * @returns {string} Absolute path to cache root (…/cache/abi-registry)
 */
export function getAbiCacheRoot(cwd = process.cwd()) {
    return join(cwd, "cache", "abi-registry");
}

/**
 * Path to Forge `out/` for a resolved git tag.
 *
 * @param {string} tag
 * @param {string} [cwd=process.cwd()]
 * @returns {string}
 */
export function getCachedOutDir(tag, cwd = process.cwd()) {
    return join(getAbiCacheRoot(cwd), tag, "out");
}

/**
 * @typedef {object} EnsureAbiCacheOptions
 * @property {string} [cwd=process.cwd()] - Git repo root (worktrees run here)
 * @property {string} [cacheRoot] - Override cache base (default: getAbiCacheRoot(cwd))
 */

/**
 * Ensures the ABI cache for a git tag exists: worktree + submodule init + `forge build --skip test`.
 * Idempotent if `{cacheRoot}/{tag}/out` already exists.
 *
 * @param {string} tag - Git tag (e.g. v3.1.0)
 * @param {EnsureAbiCacheOptions} [options]
 */
export function ensureAbiCache(tag, options = {}) {
    const cwd = options.cwd ?? process.cwd();
    const cacheRoot = options.cacheRoot ?? getAbiCacheRoot(cwd);
    const cacheOut = join(cacheRoot, tag, "out");
    if (existsSync(cacheOut)) {
        console.log(`  ✓ ABI cache hit for tag "${tag}"`);
        return;
    }

    console.log(`  Building ABI cache for tag "${tag}"...`);

    const worktreeDir = join(cacheRoot, "worktrees", tag);

    try {
        mkdirSync(join(cacheRoot, "worktrees"), { recursive: true });
        if (existsSync(worktreeDir)) {
            try {
                execSync(`git worktree remove --force "${worktreeDir}"`, { cwd, stdio: "pipe" });
            } catch {
                /* stale */
            }
            rmSync(worktreeDir, { recursive: true, force: true });
        }
        execSync(`git worktree add "${worktreeDir}" "${tag}"`, { cwd, stdio: "pipe" });

        execSync("git submodule update --init --recursive", {
            cwd: worktreeDir,
            stdio: "pipe",
        });

        execSync("forge build --skip test", {
            cwd: worktreeDir,
            stdio: "inherit",
        });

        const worktreeOut = join(worktreeDir, "out");
        if (!existsSync(worktreeOut)) {
            throw new Error(`Forge build did not produce out/ directory for tag "${tag}"`);
        }
        mkdirSync(join(cacheRoot, tag), { recursive: true });
        cpSync(worktreeOut, cacheOut, { recursive: true });
        console.log(`  ✓ ABI cache populated for tag "${tag}"`);
    } finally {
        try {
            execSync(`git worktree remove --force "${worktreeDir}"`, { cwd, stdio: "pipe" });
        } catch {
            /* ignore */
        }
        rmSync(worktreeDir, { recursive: true, force: true });
    }
}

/**
 * @param {Iterable<string>} tags
 * @param {EnsureAbiCacheOptions} [options]
 */
export function ensureAbiCachesForTags(tags, options = {}) {
    for (const tag of tags) {
        ensureAbiCache(tag, options);
    }
}

/**
 * Collects capitalized contract name → resolved git tag from a registry-style `chains` object.
 * Skips deprecated entries (`address: null`). Validates `version` and resolves via {@link resolveVersionTag}.
 *
 * @param {Object} chains - `registry.chains` shape (contracts may include `version`)
 * @returns {Map<string, string>}
 */
export function collectContractTags(chains) {
    const contractToTag = new Map();
    const errors = [];

    for (const [chainId, chain] of Object.entries(chains)) {
        for (const [name, data] of Object.entries(chain.contracts || {})) {
            if (data?.address === null) continue;

            const capitalized = name.charAt(0).toUpperCase() + name.slice(1);
            if (contractToTag.has(capitalized)) continue;

            const version = data?.version;
            if (!version) {
                errors.push(`${capitalized} on chain ${chainId} is missing a "version" field`);
                continue;
            }

            try {
                const tag = resolveVersionTag(version);
                contractToTag.set(capitalized, tag);

                if (capitalized.endsWith("Factory")) {
                    const baseName = capitalized.replace(/Factory$/, "");
                    if (!contractToTag.has(baseName)) {
                        contractToTag.set(baseName, tag);
                    }
                }
            } catch (err) {
                errors.push(`${capitalized} (version "${version}"): ${err.message}`);
            }
        }
    }

    if (errors.length > 0) {
        throw new Error(
            `Failed to resolve version tags for contracts:\n  - ${errors.join("\n  - ")}`
        );
    }

    return contractToTag;
}

/**
 * Reads ABI array from Forge JSON artifact under `out/`.
 *
 * @param {string} outputDir - Forge `out/` directory
 * @param {string} contractName - Artifact basename (e.g. Hub → Hub.json)
 * @returns {object[]|null}
 */
export function findAbiInOutput(outputDir, contractName) {
    if (!existsSync(outputDir)) return null;

    for (const abiDir of readdirSync(outputDir)) {
        if (abiDir.endsWith(".t.sol")) continue;

        const filePath = join(outputDir, abiDir, `${contractName}.json`);
        if (existsSync(filePath)) {
            const contractData = JSON.parse(readFileSync(filePath, "utf8"));
            return contractData.abi;
        }
    }
    return null;
}

/**
 * Forge artifact name for a capitalized env contract name.
 *
 * @param {string} capitalizedName
 * @returns {string}
 */
export function resolveArtifactName(capitalizedName) {
    return ABI_NAME_ALIASES[capitalizedName] || capitalizedName;
}

/**
 * Forge artifact basenames required in `registry.abis` for one `chains.*.contracts` key (camelCase).
 * Includes the factory implementation when the key ends with `Factory` (e.g. `tokenFactory` →
 * `TokenFactory` + `ShareToken`).
 *
 * @param {string} envContractKey - e.g. `fullRestrictionsHook`, `tokenFactory`
 * @returns {string[]}
 */
export function artifactNamesForContractKey(envContractKey) {
    const capitalized = envContractKey.charAt(0).toUpperCase() + envContractKey.slice(1);
    const names = [resolveArtifactName(capitalized)];
    if (capitalized.endsWith("Factory")) {
        const base = capitalized.replace(/Factory$/, "");
        names.push(resolveArtifactName(base));
    }
    return names;
}
