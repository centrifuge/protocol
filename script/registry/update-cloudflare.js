#!/usr/bin/env node
/**
 * @fileoverview Updates Cloudflare Web3 IPFS gateway DNSLink to point to new registry CIDs.
 *
 * This script updates the Cloudflare Web3 hostnames (registry.centrifuge.io and
 * registry.testnet.centrifuge.io) so they serve the latest pinned registry JSON
 * from IPFS. It uses the Cloudflare API to PATCH the gateway's dnslink to
 * /ipfs/<CID>.
 *
 * Usage:
 *   # With env vars (e.g. from pin-to-ipfs output in CI):
 *   CLOUDFLARE_ZONE_ID=<id> CLOUDFLARE_API_TOKEN=<token> \
 *   MAINNET_CID=Qm... TESTNET_CID=Qm... node script/registry/update-cloudflare.js
 *
 *   # With JSON input from stdin (e.g. from pin-to-ipfs):
 *   node script/registry/pin-to-ipfs.js | node script/registry/update-cloudflare.js --stdin
 *
 * Environment variables:
 *   CLOUDFLARE_ZONE_ID   - Cloudflare zone ID for the domain (required)
 *   CLOUDFLARE_API_TOKEN - Cloudflare API token with Web3 Hostnames Write (required)
 *   MAINNET_CID         - IPFS CID for mainnet registry (optional if not updating mainnet)
 *   TESTNET_CID         - IPFS CID for testnet registry (optional if not updating testnet)
 *   CLOUDFLARE_MAINNET_HOSTNAME - Hostname for mainnet, e.g. registry.centrifuge.io (optional)
 *   CLOUDFLARE_TESTNET_HOSTNAME - Hostname for testnet, e.g. registry.testnet.centrifuge.io (optional)
 *
 * Exit: 0 on success, 1 on error.
 */

const CLOUDFLARE_ZONE_ID = process.env.CLOUDFLARE_ZONE_ID;
const CLOUDFLARE_API_TOKEN = process.env.CLOUDFLARE_API_TOKEN;
const MAINNET_CID = process.env.MAINNET_CID || null;
const TESTNET_CID = process.env.TESTNET_CID || null;

const DEFAULT_MAINNET_HOSTNAME = "registry.centrifuge.io";
const DEFAULT_TESTNET_HOSTNAME = "registry.testnet.centrifuge.io";

const MAINNET_HOSTNAME = process.env.CLOUDFLARE_MAINNET_HOSTNAME || DEFAULT_MAINNET_HOSTNAME;
const TESTNET_HOSTNAME = process.env.CLOUDFLARE_TESTNET_HOSTNAME || DEFAULT_TESTNET_HOSTNAME;

const CLOUDFLARE_API_BASE = "https://api.cloudflare.com/client/v4";

const readStdin = process.argv.includes("--stdin");

async function readStdinJson() {
    const chunks = [];
    for await (const chunk of process.stdin) {
        chunks.push(chunk);
    }
    const raw = chunks.join("").trim();
    if (!raw) return null;
    try {
        return JSON.parse(raw);
    } catch {
        return null;
    }
}

async function listWeb3Hostnames(zoneId, token) {
    const url = `${CLOUDFLARE_API_BASE}/zones/${zoneId}/web3/hostnames`;
    const response = await fetch(url, {
        method: "GET",
        headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
        },
    });
    if (!response.ok) {
        const text = await response.text();
        throw new Error(`List hostnames failed: ${response.status} ${response.statusText} - ${text}`);
    }
    const data = await response.json();
    if (!data.success || !Array.isArray(data.result)) {
        throw new Error(`List hostnames invalid response: ${JSON.stringify(data)}`);
    }
    return data.result;
}

async function getWeb3Hostname(zoneId, token, hostnameId) {
    const url = `${CLOUDFLARE_API_BASE}/zones/${zoneId}/web3/hostnames/${hostnameId}`;
    const response = await fetch(url, {
        method: "GET",
        headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
        },
    });
    if (!response.ok) {
        const text = await response.text();
        throw new Error(`GET hostname failed: ${response.status} ${response.statusText} - ${text}`);
    }
    const data = await response.json();
    if (!data.success || !data.result) {
        throw new Error(`GET hostname invalid response: ${JSON.stringify(data)}`);
    }
    return data.result;
}

async function updateHostnameDnslink(zoneId, token, hostnameId, dnslink) {
    const url = `${CLOUDFLARE_API_BASE}/zones/${zoneId}/web3/hostnames/${hostnameId}`;
    const response = await fetch(url, {
        method: "PATCH",
        headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
        },
        body: JSON.stringify({ dnslink }),
    });
    if (!response.ok) {
        const text = await response.text();
        throw new Error(`PATCH hostname failed: ${response.status} ${response.statusText} - ${text}`);
    }
    const data = await response.json();
    if (!data.success) {
        throw new Error(`PATCH hostname invalid response: ${JSON.stringify(data)}`);
    }
    return data.result;
}

async function main() {
    let mainnetCid = MAINNET_CID;
    let testnetCid = TESTNET_CID;

    if (readStdin) {
        const input = await readStdinJson();
        if (input) {
            if (input.mainnet?.cid) mainnetCid = input.mainnet.cid;
            if (input.testnet?.cid) testnetCid = input.testnet.cid;
        }
    }

    if (!CLOUDFLARE_ZONE_ID || !CLOUDFLARE_API_TOKEN) {
        console.error("Error: CLOUDFLARE_ZONE_ID and CLOUDFLARE_API_TOKEN are required");
        process.exit(1);
    }

    if (!mainnetCid && !testnetCid) {
        console.log("No MAINNET_CID or TESTNET_CID provided; nothing to update");
        process.exit(0);
    }

    const hostnames = await listWeb3Hostnames(CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN);
    const byName = new Map(hostnames.map((h) => [h.name, h]));

    const updates = [];
    if (mainnetCid && byName.has(MAINNET_HOSTNAME)) {
        updates.push({ hostname: MAINNET_HOSTNAME, cid: mainnetCid, id: byName.get(MAINNET_HOSTNAME).id });
    } else if (mainnetCid && !byName.has(MAINNET_HOSTNAME)) {
        console.warn(`Warning: mainnet hostname "${MAINNET_HOSTNAME}" not found in zone; skipping mainnet update`);
    }
    if (testnetCid && byName.has(TESTNET_HOSTNAME)) {
        updates.push({ hostname: TESTNET_HOSTNAME, cid: testnetCid, id: byName.get(TESTNET_HOSTNAME).id });
    } else if (testnetCid && !byName.has(TESTNET_HOSTNAME)) {
        console.warn(`Warning: testnet hostname "${TESTNET_HOSTNAME}" not found in zone; skipping testnet update`);
    }

    if (updates.length === 0) {
        console.log("No hostnames to update");
        process.exit(0);
    }

    for (const { hostname, cid, id } of updates) {
        const dnslink = `/ipfs/${cid}`;
        console.log(`Updating ${hostname} -> ${dnslink}...`);
        await updateHostnameDnslink(CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN, id, dnslink);
        console.log(`  ✓ ${hostname} updated`);
    }

    console.log("Cloudflare Web3 URLs updated successfully");
}

main().catch((err) => {
    console.error(err.message || err);
    process.exit(1);
});
