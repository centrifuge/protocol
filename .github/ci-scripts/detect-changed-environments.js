#!/usr/bin/env node
/**
 * @fileoverview Detects which environments (mainnet/testnet) have changed env files.
 * 
 * Usage:
 *   node .github/ci-scripts/detect-changed-environments.js
 * 
 * Output: Prints JSON with changed environments:
 *   {"mainnet": true, "testnet": false}
 *   or {"mainnet": false, "testnet": true}
 *   or {"mainnet": true, "testnet": true}
 */

import { readdirSync, readFileSync } from "fs";
import { join } from "path";
import { execSync } from "child_process";

const envDir = join(process.cwd(), "env");
const changedEnvs = { mainnet: false, testnet: false };

/**
 * Resolves a ref name to something `git rev-parse` recognises in this checkout.
 * In CI (`actions/checkout@v3`) only remote-tracking refs like `origin/main` exist;
 * `GITHUB_BASE_REF=main` alone fails with "bad revision 'main'", which used to drop
 * the script into the "all env files changed" fallback (false positive: mainnet=true).
 */
function resolveRef(rawRef) {
    if (!rawRef) return null;
    for (const candidate of [rawRef, `origin/${rawRef}`, `refs/remotes/origin/${rawRef}`]) {
        try {
            execSync(`git rev-parse --verify ${candidate}^{commit}`, { stdio: "pipe" });
            return candidate;
        } catch {
            /* try next */
        }
    }
    return null;
}

let changedFiles = [];
try {
    // For PRs (`pull_request` event): GITHUB_BASE_REF is the target branch name (e.g. "main").
    // For push events: GITHUB_BASE_REF is empty, so we diff HEAD^..HEAD.
    const rawBase = process.env.GITHUB_BASE_REF;
    const baseRef = rawBase ? resolveRef(rawBase) : "HEAD^";
    const headRef = "HEAD"; // checkout points HEAD at the PR merge ref / push commit

    if (rawBase && !baseRef) {
        // PR base is set but neither `main` nor `origin/main` resolved — abort to "both"
        // so we don't silently produce a wrong answer.
        console.warn(
            `Could not resolve base ref "${rawBase}" (tried local + origin/); assuming both environments changed`
        );
        changedEnvs.mainnet = true;
        changedEnvs.testnet = true;
        console.log(JSON.stringify(changedEnvs));
        process.exit(0);
    }

    try {
        const diff = execSync(
            `git diff --name-only ${baseRef} ${headRef} -- env/`,
            { encoding: "utf8", cwd: process.cwd(), stdio: ["ignore", "pipe", "pipe"] }
        );
        changedFiles = diff.trim().split("\n").filter(Boolean);
    } catch (error) {
        // First commit / shallow clone / detached state — fall back to all files (loud warning,
        // not silent). Caller can still inspect the log line in CI.
        console.warn(
            `Could not determine changed files via "git diff ${baseRef} ${headRef}", checking all env files: ${error.message}`
        );
        changedFiles = readdirSync(envDir)
            .filter(f => f.endsWith(".json"))
            .map(f => join("env", f));
    }
} catch (error) {
    console.warn(`Could not detect changed files (${error.message}); assuming both environments changed`);
    changedEnvs.mainnet = true;
    changedEnvs.testnet = true;
    console.log(JSON.stringify(changedEnvs));
    process.exit(0);
}

// Check which environments the changed files belong to
for (const filePath of changedFiles) {
    if (!filePath.includes("env/") || !filePath.endsWith(".json")) continue;
    
    try {
        const fullPath = filePath.startsWith("env/") 
            ? join(process.cwd(), filePath)
            : filePath;
        const chain = JSON.parse(readFileSync(fullPath, "utf8"));
        const environment = chain.network?.environment;
        
        if (environment === "mainnet") {
            changedEnvs.mainnet = true;
        } else if (environment === "testnet") {
            changedEnvs.testnet = true;
        }
    } catch (error) {
        console.warn(`Could not parse ${filePath}: ${error.message}`);
    }
}

// If no env changes detected, leave both false so only changed environments are built
if (!changedEnvs.mainnet && !changedEnvs.testnet) {
    console.warn("No environment changes detected; mainnet and testnet will not be built.");
}

console.log(JSON.stringify(changedEnvs));

