/**
 * Resolves env contract `version` strings to local git tags (shared by abi-registry and CI validation).
 */

import { execSync } from "child_process";

/**
 * @param {string} tag
 * @returns {boolean}
 */
export function gitTagExists(tag) {
    try {
        execSync(`git rev-parse --verify refs/tags/${tag}`, { stdio: "pipe" });
        return true;
    } catch {
        return false;
    }
}

/**
 * Ordered list of tag candidates for a contract version (no I/O).
 * @param {string} version
 * @returns {string[]}
 */
export function versionTagCandidates(version) {
    const candidates = [version];
    if (!version.startsWith("v")) {
        candidates.push(`v${version}`);
    }
    const withPatch = candidates.map((c) => `${c}.0`);
    candidates.push(...withPatch);
    return candidates;
}

/**
 * Resolves a git tag for a contract version string.
 * Tries candidates, then optional `git fetch --tags` and retries.
 *
 * @param {string} version - From env contract (e.g. "3", "v3.1")
 * @param {{ fetchTagsOnMiss?: boolean }} [opts]
 * @returns {string} Resolved tag name
 * @throws {Error} If no tag matches
 */
export function resolveVersionTag(version, opts = {}) {
    const { fetchTagsOnMiss = true } = opts;
    const candidates = versionTagCandidates(version);

    for (const candidate of candidates) {
        if (gitTagExists(candidate)) return candidate;
    }

    if (fetchTagsOnMiss) {
        try {
            execSync("git fetch --tags --quiet", { stdio: "pipe" });
        } catch {
            // best-effort
        }
        for (const candidate of candidates) {
            if (gitTagExists(candidate)) return candidate;
        }
    }

    throw new Error(
        `No git tag found for contract version "${version}". ` +
            `Tried: ${candidates.join(", ")}. ` +
            `Every contract version in env files must have a corresponding git tag.`
    );
}
