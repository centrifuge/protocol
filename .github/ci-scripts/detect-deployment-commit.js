#!/usr/bin/env node
/**
 * @fileoverview Detects the deployment git commit for a given environment (mainnet/testnet).
 * 
 * This script scans all env/*.json files and extracts gitCommit values from deploymentInfo
 * for chains matching the specified environment. It outputs the first commit found, which
 * is used by the CI workflow to determine which codebase version to build for ABI extraction.
 * 
 * Usage:
 *   node .github/ci-scripts/detect-deployment-commit.js [mainnet|testnet]
 * 
 * Output: Prints the git commit hash to stdout (or exits with error if none found).
 * 
 * Note: Different chains within the same environment may have different deployment commits.
 * This script picks the first one found as a pragmatic approach until a better strategy
 * is implemented (e.g., using the most recent commit, or requiring explicit specification).
 */

import { readdirSync, readFileSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";

// Environment selector: "mainnet" or "testnet" (defaults to "mainnet")
const selector = process.argv.length > 2 ? process.argv.at(-1) : "mainnet";
const envDir = join(process.cwd(), "env");
const commits = new Set();

// Scan all env/*.json files for deployment git commits matching the environment
for (const file of readdirSync(envDir)) {
    if (!file.endsWith(".json")) continue;
    const chain = JSON.parse(readFileSync(join(envDir, file), "utf8"));

    // Filter by environment (mainnet/testnet)
    if (chain.network?.environment !== selector) continue;

    // Extract gitCommit from deploymentInfo (supports nested structures like "deploy:protocol")
    const info = chain.deploymentInfo;
    if (!info || typeof info !== "object") continue;
    for (const value of Object.values(info)) {
        if (value?.gitCommit) {
            commits.add(value.gitCommit);
        }
    }
}

if (commits.size === 0) {
    console.error(`No deploymentInfo.gitCommit found for environment "${selector}" in env/*.json files.`);
    process.exit(1);
}

// Choose which deployment commit to use:
// - If there's a single commit, use it.
// - If multiple, pick the most recent one by commit date.
let selectedCommit = null;

if (commits.size === 1) {
    selectedCommit = commits.values().next().value;
} else {
    const commitList = Array.from(commits);
    const validCommits = [];

    for (const sha of commitList) {
        try {
            // %ct = commit timestamp (Unix seconds)
            const ts = execSync(`git show -s --format=%ct "${sha}"`, {
                encoding: "utf8",
                cwd: process.cwd(),
                stdio: ["ignore", "pipe", "pipe"],
            }).trim();
            const timestamp = Number(ts);
            if (!Number.isNaN(timestamp)) {
                validCommits.push({ sha, timestamp });
            }
        } catch {
            console.warn(`Warning: deployment commit "${sha}" not found locally, skipping`);
        }
    }

    if (validCommits.length === 0) {
        console.error(
            `No valid deployment commits could be resolved for environment "${selector}". ` +
            `Checked SHAs: ${commitList.join(", ")}`
        );
        process.exit(1);
    }

    // Pick commit with max timestamp
    validCommits.sort((a, b) => b.timestamp - a.timestamp);
    selectedCommit = validCommits[0].sha;

    console.warn(
        `Warning: Multiple deployment git commits found for "${selector}": ${commitList.join(
            ", "
        )}. Using most recent: ${selectedCommit}`
    );
}

// Expand short SHA to full SHA using git rev-parse
// This ensures we always return a full 40-character SHA for git fetch operations
let fullCommit = selectedCommit;

// If it's already a full SHA (40 chars), use it as-is
// Otherwise, try to expand it using git rev-parse
if (fullCommit.length !== 40) {
    try {
        // First, try to expand using local git repository (no network needed)
        const expanded = execSync(`git rev-parse "${fullCommit}"`, {
            encoding: "utf8",
            cwd: process.cwd(),
            stdio: ["ignore", "pipe", "pipe"],
        }).trim();

        if (expanded && expanded.length === 40) {
            fullCommit = expanded;
        } else {
            console.warn(`Warning: Could not expand commit "${selectedCommit}" to full SHA locally`);
            // If local expansion fails, try fetching from origin (for CI environments)
            try {
                execSync("git fetch origin --tags --unshallow 2>/dev/null || git fetch origin --tags --depth=5000", {
                    stdio: "ignore",
                    cwd: process.cwd(),
                });
                const fetchedExpanded = execSync(`git rev-parse "${fullCommit}"`, {
                    encoding: "utf8",
                    cwd: process.cwd(),
                    stdio: ["ignore", "pipe", "pipe"],
                }).trim();
                if (fetchedExpanded && fetchedExpanded.length === 40) {
                    fullCommit = fetchedExpanded;
                }
            } catch (fetchError) {
                console.warn(`Warning: Could not fetch from origin to expand commit: ${fetchError.message}`);
            }
        }
    } catch (error) {
        // If local rev-parse fails, try fetching from origin as fallback
        try {
            execSync("git fetch origin --tags --unshallow 2>/dev/null || git fetch origin --tags --depth=5000", {
                stdio: "ignore",
                cwd: process.cwd(),
            });
            const expanded = execSync(`git rev-parse "${fullCommit}"`, {
                encoding: "utf8",
                cwd: process.cwd(),
                stdio: ["ignore", "pipe", "pipe"],
            }).trim();
            if (expanded && expanded.length === 40) {
                fullCommit = expanded;
            } else {
                console.warn(`Warning: Could not expand commit "${selectedCommit}" to full SHA, using as-is`);
            }
        } catch (fetchError) {
            console.warn(`Warning: Could not expand commit "${selectedCommit}" to full SHA: ${error.message}`);
            console.warn(`Using short SHA as-is (this may cause issues with git fetch)`);
        }
    }
}

// Output the full commit hash for use in CI workflow
console.log(fullCommit);

