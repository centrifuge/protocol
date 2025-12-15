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

// Get list of changed env files
let changedFiles = [];
try {
    // For push events, compare with previous commit
    // For PRs, compare with base branch
    const baseRef = process.env.GITHUB_BASE_REF || "HEAD^";
    const headRef = process.env.GITHUB_HEAD_REF || "HEAD";
    
    // Try to get changed files
    try {
        const diff = execSync(
            `git diff --name-only ${baseRef} ${headRef} -- env/*.json env/**/*.json`,
            { encoding: "utf8", cwd: process.cwd() }
        );
        changedFiles = diff.trim().split("\n").filter(Boolean);
    } catch (error) {
        // If diff fails (e.g., first commit), check all files
        console.warn("Could not determine changed files, checking all env files");
        changedFiles = readdirSync(envDir)
            .filter(f => f.endsWith(".json"))
            .map(f => join("env", f));
    }
} catch (error) {
    // Fallback: if we can't determine changes, assume both changed
    console.warn("Could not detect changed files, assuming both environments changed");
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

// If no changes detected, default to both (safety fallback)
if (!changedEnvs.mainnet && !changedEnvs.testnet) {
    console.warn("No environment changes detected, defaulting to both");
    changedEnvs.mainnet = true;
    changedEnvs.testnet = true;
}

console.log(JSON.stringify(changedEnvs));

