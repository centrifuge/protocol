#!/usr/bin/env node
/**
 * @fileoverview Master script to run the full registry pipeline: ABI registry generation,
 * validation, IPFS pinning, and Cloudflare Web3 URL update.
 *
 * Steps:
 *   1. abi-registry.js mainnet (and testnet)
 *   2. validate-registry.js on registry-mainnet.json and registry-testnet.json
 *   3. pin-to-ipfs.js
 *   4. update-cloudflare.js (if CLOUDFLARE_* env vars are set and CIDs were produced)
 *
 * Usage (from repo root):
 *   # Full pipeline (requires ETHERSCAN_API_KEY, PINATA_JWT; optional CLOUDFLARE_* for step 4):
 *   node script/registry/run-registry-pipeline.js
 *
 *   # Mainnet only:
 *   node script/registry/run-registry-pipeline.js --mainnet-only
 *
 *   # Testnet only:
 *   node script/registry/run-registry-pipeline.js --testnet-only
 *
 *   # Skip Cloudflare update even if env is set:
 *   node script/registry/run-registry-pipeline.js --no-cloudflare
 *
 * Note: For correct registry content, build at deployment commits first (see .github/workflows/registry.yml).
 * Step 4 runs only when CLOUDFLARE_ZONE_ID and CLOUDFLARE_API_TOKEN are set.
 */

import { execSync, spawnSync } from "child_process";
import { existsSync } from "fs";
import { join, dirname } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const repoRoot = join(__dirname, "..", "..");

const args = process.argv.slice(2);
const mainnetOnly = args.includes("--mainnet-only");
const testnetOnly = args.includes("--testnet-only");
const noCloudflare = args.includes("--no-cloudflare");

function run(cmd, options = {}) {
    const { capture = false, env } = options;
    const execOpts = {
        cwd: repoRoot,
        encoding: "utf8",
        stdio: capture ? "pipe" : "inherit",
        ...(env && { env: { ...process.env, ...env } }),
    };
    const result = execSync(cmd, execOpts);
    return capture ? result : undefined;
}

function step(name, fn) {
    console.log(`\n=== ${name} ===\n`);
    try {
        fn();
    } catch (err) {
        console.error(`Step failed: ${name}`);
        if (err.stdout) console.error(err.stdout);
        if (err.stderr) console.error(err.stderr);
        throw err;
    }
}

// Parse pin-to-ipfs JSON from stdout (last line that looks like JSON)
function parsePinOutput(stdout) {
    if (!stdout || typeof stdout !== "string") return null;
    const lines = stdout.trim().split("\n").filter(Boolean);
    for (let i = lines.length - 1; i >= 0; i--) {
        const line = lines[i].trim();
        if (line.startsWith("{") && line.endsWith("}")) {
            try {
                return JSON.parse(line);
            } catch {
                continue;
            }
        }
    }
    return null;
}

function main() {
    step("1. Generate ABI registry", () => {
        if (!testnetOnly) {
            run("node script/registry/abi-registry.js mainnet");
        }
        if (!mainnetOnly) {
            run("node script/registry/abi-registry.js testnet");
        }
    });

    step("2. Validate registry", () => {
        const mainnetPath = join(repoRoot, "registry", "registry-mainnet.json");
        const testnetPath = join(repoRoot, "registry", "registry-testnet.json");
        if (existsSync(mainnetPath)) {
            run("node script/registry/utils/validate-registry.js registry/registry-mainnet.json");
        }
        if (existsSync(testnetPath)) {
            run("node script/registry/utils/validate-registry.js registry/registry-testnet.json");
        }
    });

    let pinResult = null;
    step("3. Pin registry to IPFS", () => {
        const out = run("node script/registry/pin-to-ipfs.js", { capture: true });
        if (out) console.log(out);
        pinResult = parsePinOutput(out);
        if (!pinResult) {
            console.warn("Could not parse pin-to-ipfs JSON output; Cloudflare step may be skipped.");
        }
    });

    const runCloudflare =
        !noCloudflare &&
        process.env.CLOUDFLARE_ZONE_ID &&
        process.env.CLOUDFLARE_API_TOKEN &&
        pinResult &&
        (pinResult.mainnet?.cid || pinResult.testnet?.cid);

    if (runCloudflare) {
        step("4. Update Cloudflare Web3 URL", () => {
            const env = {
                ...process.env,
                ...(pinResult.mainnet?.cid && { MAINNET_CID: pinResult.mainnet.cid }),
                ...(pinResult.testnet?.cid && { TESTNET_CID: pinResult.testnet.cid }),
            };
            run("node script/registry/update-cloudflare.js", { env });
        });
    } else {
        console.log("\n=== 4. Update Cloudflare (skipped) ===\n");
        if (!process.env.CLOUDFLARE_ZONE_ID || !process.env.CLOUDFLARE_API_TOKEN) {
            console.log("CLOUDFLARE_ZONE_ID and CLOUDFLARE_API_TOKEN not set.");
        } else if (!pinResult?.mainnet?.cid && !pinResult?.testnet?.cid) {
            console.log("No new CIDs from pin step (registries unchanged or not pinned).");
        } else {
            console.log("Cloudflare update skipped (--no-cloudflare or no CIDs).");
        }
    }

    console.log("\n✓ Registry pipeline complete.\n");
}

main();
