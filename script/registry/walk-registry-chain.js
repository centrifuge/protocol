#!/usr/bin/env node
/**
 * @fileoverview Ops tool: audits the published registry chain layer by layer.
 *
 * Walks `previousRegistry.ipfsHash` from a tip back to the base snapshot and prints what each layer
 * carries. The contracts-per-layer column is the point: a healthy chain shows small layers on top
 * of a large base snapshot, while a layer carrying nearly as many contracts as the whole registry
 * means that publish compared against the wrong baseline and shipped a snapshot as a delta.
 *
 * The walk itself, the gateways, and the layer cache come from utils/, so this shares behavior with
 * generation rather than reimplementing it.
 *
 * Usage:
 *   node script/registry/walk-registry-chain.js mainnet
 *   node script/registry/walk-registry-chain.js testnet --depth 100
 *   node script/registry/walk-registry-chain.js --cid <cid>
 *   node script/registry/walk-registry-chain.js mainnet --json
 *
 * Exits non-zero when the chain cannot be walked to its base snapshot.
 */

import { collectRegistryChain, summarizeAccumulatedState } from "./utils/registry-chain.js";
import { fetchLiveRegistry, fetchRegistryFromIpfs, isValidIpfsHash } from "./utils/registry-fetch.js";

const args = process.argv.slice(2);
let network = null;
let startCid = null;
let maxDepth;
let asJson = false;

for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--json") asJson = true;
    else if (arg === "--cid") startCid = args[++i];
    else if (arg === "--depth") maxDepth = Number(args[++i]);
    else if (arg === "mainnet" || arg === "testnet") network = arg;
    else {
        console.error(`Unknown argument: ${arg}`);
        console.error("Usage: node script/registry/walk-registry-chain.js <mainnet|testnet> [--depth N] [--json]");
        console.error("       node script/registry/walk-registry-chain.js --cid <cid> [--depth N] [--json]");
        process.exit(1);
    }
}

if (!network && !startCid) {
    console.error("Specify an environment (mainnet|testnet) or --cid <cid>.");
    process.exit(1);
}
if (startCid && !isValidIpfsHash(startCid)) {
    console.error(`Not a valid IPFS CID: ${startCid}`);
    process.exit(1);
}
if (maxDepth !== undefined && !Number.isInteger(maxDepth)) {
    console.error("--depth expects an integer.");
    process.exit(1);
}

/** Counts contracts and tombstones a single layer carries. */
function describeLayer(registry) {
    let contracts = 0;
    let tombstones = 0;
    for (const chainData of Object.values(registry?.chains || {})) {
        for (const entry of Object.values(chainData?.contracts || {})) {
            contracts++;
            if (entry?.address === null) tombstones++;
        }
    }
    return {
        version: registry?.version ?? null,
        gitCommit: registry?.deploymentInfo?.gitCommit ?? null,
        cid: registry?.previousRegistry?.ipfsHash ?? null, // the CID this layer points at
        chains: Object.keys(registry?.chains || {}).length,
        contracts,
        tombstones,
    };
}

function pad(value, width) {
    const text = value === null || value === undefined ? "-" : String(value);
    return text.length > width ? `${text.slice(0, width - 1)}…` : text.padEnd(width);
}

function printTable(rows, accumulatedContracts) {
    console.log("");
    console.log(
        `${pad("#", 4)}${pad("Version", 14)}${pad("Git commit", 12)}${pad("Chains", 8)}${pad("Contracts", 11)}${pad("Tombstones", 12)}Points at`
    );
    console.log("─".repeat(100));

    rows.forEach((row, index) => {
        // Flag layers that carry an implausible share of the whole registry for a single publish.
        const suspicious = accumulatedContracts > 0 && row.contracts / accumulatedContracts > 0.5;
        const marker = index === 0 ? " (base)" : suspicious ? "  ⚠ snapshot-sized" : "";
        console.log(
            `${pad(index, 4)}${pad(row.version ?? "null (patch)", 14)}${pad(row.gitCommit?.slice(0, 9), 12)}` +
            `${pad(row.chains, 8)}${pad(row.contracts, 11)}${pad(row.tombstones, 12)}` +
            `${row.cid ? row.cid.slice(0, 12) + "…" : "(base snapshot)"}${marker}`
        );
    });
    console.log("─".repeat(100));
}

async function main() {
    let tip;
    if (startCid) {
        console.log(`Registry chain walk from CID ${startCid}`);
        tip = await fetchRegistryFromIpfs(startCid, { log: console.log });
    } else {
        console.log(`Registry chain walk: ${network}`);
        tip = await fetchLiveRegistry(network);
        if (!tip) {
            console.error(`Could not read the live registry for ${network}.`);
            process.exit(1);
        }
    }

    const { layers, accumulated, complete, reason } = await collectRegistryChain(tip, {
        maxDepth,
        // An explicit --cid may legitimately point at either environment, so only the
        // network-selected walk asserts which environment the layers must belong to.
        expectedNetwork: startCid ? null : network,
        log: console.log,
    });

    const { chains, contracts } = summarizeAccumulatedState(accumulated);
    const rows = layers.map(describeLayer); // oldest → newest

    if (asJson) {
        console.log(
            JSON.stringify(
                { complete, reason, layers: rows, accumulated: { chains, contracts } },
                null,
                2
            )
        );
    } else {
        printTable(rows, contracts);
        console.log(`Layers: ${layers.length}`);
        console.log(`Accumulated state: ${contracts} contracts across ${chains} chain(s)`);
        if (complete) {
            console.log("✓ Chain walks cleanly to its base snapshot.");
        } else {
            console.log(`✗ Chain is incomplete: ${reason}`);
        }
    }

    if (!complete) process.exit(1);
}

main().catch((error) => {
    console.error(`\nError: ${error.message}`);
    process.exit(1);
});
