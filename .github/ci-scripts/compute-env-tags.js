#!/usr/bin/env node
/**
 * @fileoverview Computes git tag names for environment file updates.
 * 
 * This script detects which env/*.json files were modified in the current commit
 * and generates tag names for the deployment commits referenced in those files.
 * 
 * Usage:
 *   node .github/ci-scripts/compute-env-tags.js
 * 
 * Output: Prints `tag SHA` pairs to stdout (one per line), or nothing if no env files changed.
 * 
 * Tag format: deploy-${environment}-${version}-${shortSha}
 *   - environment: from `network.environment` (e.g. mainnet, testnet)
 *   - version: highest semver found across all contracts[*].version in the env file
 *   - shortSha: first 7 chars of the deployment gitCommit
 * 
 * The tag points directly to the deployment commit SHA referenced in the env file,
 * not to the workflow's HEAD. This ensures the deployment commit remains reachable
 * even after squashing or rebasing feature branches.
 */

import { readFileSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";

/**
 * Gets the list of modified env files between HEAD^ and HEAD
 * @returns {string[]} Array of file paths relative to repo root
 */
function getModifiedEnvFiles() {
    try {
        // Check if we have a previous commit (HEAD^ exists)
        try {
            execSync("git rev-parse --verify HEAD^", { stdio: "ignore" });
        } catch {
            // No previous commit (first commit in repo), list all env files in HEAD
            // Use git ls-tree to get files in HEAD
            const output = execSync("git ls-tree -r --name-only HEAD -- env/", {
                encoding: "utf8",
                stdio: ["ignore", "pipe", "ignore"],
            });
            // Filter to only .json files
            return output.trim().split("\n").filter((f) => f.endsWith(".json"));
        }

        // Get files changed between HEAD^ and HEAD
        const output = execSync("git diff --name-only HEAD^ HEAD -- env/", {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "ignore"],
        });
        // Filter to only .json files
        return output.trim().split("\n").filter((f) => f.endsWith(".json"));
    } catch (error) {
        // If git command fails, return empty array
        return [];
    }
}

/**
 * Extracts tag info (environment, version, gitCommit) from deploymentInfo in an env file.
 * @param {string} filePath - Path to env JSON file
 * @returns {Array<{ environment: string, version: string|null, gitCommit: string }>}
 */
function extractTagInfo(filePath) {
    try {
        const content = readFileSync(filePath, "utf8");
        const chain = JSON.parse(content);
        const environment = chain.network?.environment;
        const deploymentInfo = chain.deploymentInfo;

        if (!environment || !deploymentInfo || typeof deploymentInfo !== "object") {
            return [];
        }

        // Determine the version from the highest version found across all contracts
        const version = findHighestContractVersion(chain.contracts);

        const results = [];

        // Look for deploy:protocol gitCommit
        const protocolDeploy = deploymentInfo["deploy:protocol"];
        if (protocolDeploy?.gitCommit) {
            results.push({
                environment,
                version,
                gitCommit: protocolDeploy.gitCommit,
            });
        }

        // Fallback: check any other deploymentInfo entry for gitCommit
        for (const [key, value] of Object.entries(deploymentInfo)) {
            if (key === "deploy:protocol") continue;
            if (value?.gitCommit) {
                results.push({
                    environment,
                    version,
                    gitCommit: value.gitCommit,
                });
            }
        }

        return results;
    } catch (error) {
        // If file read/parse fails, return nothing for this file
        return [];
    }
}

/**
 * Generates a timestamp string in YYYYMMDD-HHMMSS format (UTC)
 * @returns {string} Timestamp string
 */
function generateTimestamp() {
    const now = new Date();
    const year = now.getUTCFullYear();
    const month = String(now.getUTCMonth() + 1).padStart(2, "0");
    const day = String(now.getUTCDate()).padStart(2, "0");
    const hours = String(now.getUTCHours()).padStart(2, "0");
    const minutes = String(now.getUTCMinutes()).padStart(2, "0");
    const seconds = String(now.getUTCSeconds()).padStart(2, "0");

    return `${year}${month}${day}-${hours}${minutes}${seconds}`;
}

/**
 * Parses a version string into its numeric components.
 * Supports formats: "v3.1.0", "v3.1", "v3", "3.1.0", "3.1", "3" (optional 'v' prefix)
 * @param {string} versionStr - Version string to parse
 * @returns {{ major: number, minor: number, patch: number, original: string } | null}
 */
function parseVersion(versionStr) {
    if (!versionStr || typeof versionStr !== "string") return null;
    const cleaned = versionStr.replace(/^v/i, "");
    const parts = cleaned.split(".").map((p) => parseInt(p, 10));
    if (parts.length === 0 || parts.some(isNaN)) return null;
    return {
        major: parts[0] || 0,
        minor: parts[1] || 0,
        patch: parts[2] || 0,
        original: versionStr,
    };
}

/**
 * Compares two parsed versions. Returns positive if a > b, negative if a < b, 0 if equal.
 * @param {{ major: number, minor: number, patch: number }} a
 * @param {{ major: number, minor: number, patch: number }} b
 * @returns {number}
 */
function compareVersions(a, b) {
    if (a.major !== b.major) return a.major - b.major;
    if (a.minor !== b.minor) return a.minor - b.minor;
    return a.patch - b.patch;
}

/**
 * Finds the highest version across all contracts in the env file.
 * @param {Object} contracts - The contracts object from the env JSON
 * @returns {string|null} The highest version string found, or null if none
 */
function findHighestContractVersion(contracts) {
    if (!contracts || typeof contracts !== "object") return null;
    let highest = null;
    for (const contract of Object.values(contracts)) {
        if (!contract?.version) continue;
        const parsed = parseVersion(contract.version);
        if (!parsed) continue;
        if (!highest || compareVersions(parsed, highest) > 0) {
            highest = parsed;
        }
    }
    return highest?.original || null;
}

/**
 * Sanitizes a version string for use in a git tag name
 * @param {string} version - Version string (e.g., "v3.1", "test-v3.0.1")
 * @returns {string} Sanitized version string
 */
function sanitizeVersion(version) {
    // Replace invalid characters for git tags with hyphens
    // Git tags can contain: alphanumeric, -, _, .
    return version.replace(/[^a-zA-Z0-9._-]/g, "-");
}

// Main execution
const modifiedFiles = getModifiedEnvFiles();

if (modifiedFiles.length === 0) {
    // No env files changed, exit silently
    process.exit(0);
}

// Collect unique (environment, version, gitCommit) triples from modified files
const entries = new Map(); // key: env|version|sha, value: { environment, version, gitCommit }

for (const file of modifiedFiles) {
    const infoList = extractTagInfo(file);
    for (const info of infoList) {
        if (!info.gitCommit) continue;
        const key = `${info.environment}|${info.version || "unknown"}|${info.gitCommit}`;
        if (!entries.has(key)) {
            entries.set(key, info);
        }
    }
}

if (entries.size === 0) {
    // No deployment commits found, exit silently
    process.exit(0);
}

// Generate tags for each unique deployment commit
for (const { environment, version, gitCommit } of entries.values()) {
    const sanitizedVersion = sanitizeVersion(version || "unknown");
    const shortSha = gitCommit.slice(0, 7);
    const tag = `deploy-${environment}-${sanitizedVersion}-${shortSha}`;
    // Output `tag SHA` so the workflow can tag the correct commit
    console.log(`${tag} ${gitCommit}`);
}

