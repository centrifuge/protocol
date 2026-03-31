#!/usr/bin/env node
/**
 * @fileoverview Validates Pinata and Cloudflare API keys without changing anything.
 *
 * - Pinata: lists pins (read-only). Proves PINATA_JWT works.
 * - Cloudflare: lists Web3 hostnames (read), then optionally PATCHes each
 *   hostname with its current dnslink (no-op write). Proves token can read and write.
 *
 * Usage (from repo root):
 *   cd script/registry && npm install
 *   PINATA_JWT=<jwt> node validate-api-keys.js
 *   CLOUDFLARE_ZONE_ID=<id> CLOUDFLARE_API_TOKEN=<token> node validate-api-keys.js
 *   # If token verify fails with "Invalid API Token", use account-scoped verify (account ID from dashboard):
 *   CLOUDFLARE_ACCOUNT_ID=<account_id> CLOUDFLARE_ZONE_ID=... CLOUDFLARE_API_TOKEN=... node validate-api-keys.js
 *   # Both and test Cloudflare write (PATCH same dnslink = no change):
 *   PINATA_JWT=... CLOUDFLARE_ZONE_ID=... CLOUDFLARE_API_TOKEN=... node validate-api-keys.js --test-write
 *
 * Options:
 *   --test-write   For Cloudflare, also PATCH each hostname with its current dnslink (proves write; no change).
 *   --pinata-only  Only validate Pinata.
 *   --cloudflare-only  Only validate Cloudflare.
 */

import { PinataSDK } from "pinata";

const PINATA_JWT = process.env.PINATA_JWT;
const CLOUDFLARE_ZONE_ID = process.env.CLOUDFLARE_ZONE_ID;
const CLOUDFLARE_ACCOUNT_ID = process.env.CLOUDFLARE_ACCOUNT_ID; // optional; use for token verify when token is account-scoped
const CLOUDFLARE_API_TOKEN = process.env.CLOUDFLARE_API_TOKEN;
const MAINNET_HOSTNAME = process.env.CLOUDFLARE_MAINNET_HOSTNAME || "registry.centrifuge.io";
const TESTNET_HOSTNAME = process.env.CLOUDFLARE_TESTNET_HOSTNAME || "registry.testnet.centrifuge.io";
const CF_API = "https://api.cloudflare.com/client/v4";

const testWrite = process.argv.includes("--test-write");
const pinataOnly = process.argv.includes("--pinata-only");
const cloudflareOnly = process.argv.includes("--cloudflare-only");

async function validatePinata() {
    if (!PINATA_JWT) {
        console.log("Pinata: skip (PINATA_JWT not set)");
        return;
    }
    try {
        const pinata = new PinataSDK({ pinataJwt: PINATA_JWT });
        const response = await pinata.files.public.list().limit(1);
        const files = response?.files ?? [];
        console.log("Pinata: OK (list works, key valid)");
        if (files.length > 0) {
            console.log(`  Sample: ${files[0].name ?? files[0].cid} (${files.length} item(s) in first page)`);
        }
    } catch (err) {
        console.error("Pinata: FAIL -", err.message || err);
        throw err;
    }
}

async function verifyCloudflareToken(token) {
    // Account-scoped tokens must use /accounts/:id/tokens/verify; /user/tokens/verify can return "Invalid API Token"
    const verifyUrl = CLOUDFLARE_ACCOUNT_ID
        ? `${CF_API}/accounts/${CLOUDFLARE_ACCOUNT_ID}/tokens/verify`
        : `${CF_API}/user/tokens/verify`;
    const res = await fetch(verifyUrl, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });
    const data = await res.json();
    if (!res.ok || !data.success) {
        const msg = data.errors?.[0]?.message || `Token verify failed: ${res.status}`;
        const hint =
            /invalid|expired|authentication/i.test(msg)
                ? " Check the token is active, not expired, and copied in full (no leading/trailing spaces). Create a new token in Cloudflare if needed."
                : "";
        throw new Error(msg + hint);
    }
    return data.result;
}

async function listZones(token) {
    const res = await fetch(`${CF_API}/zones?per_page=50`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });
    if (!res.ok) throw new Error(`List zones: ${res.status} ${await res.text()}`);
    const data = await res.json();
    if (!data.success || !Array.isArray(data.result)) throw new Error(`List zones: ${JSON.stringify(data)}`);
    return data.result;
}

async function listWeb3Hostnames(zoneId, token) {
    const res = await fetch(`${CF_API}/zones/${zoneId}/web3/hostnames`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });
    if (!res.ok) throw new Error(`List hostnames: ${res.status} ${await res.text()}`);
    const data = await res.json();
    if (!data.success || !Array.isArray(data.result)) throw new Error(`List hostnames: ${JSON.stringify(data)}`);
    return data.result;
}

async function getWeb3Hostname(zoneId, token, hostnameId) {
    const res = await fetch(`${CF_API}/zones/${zoneId}/web3/hostnames/${hostnameId}`, {
        method: "GET",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });
    if (!res.ok) throw new Error(`GET hostname: ${res.status} ${await res.text()}`);
    const data = await res.json();
    if (!data.success || !data.result) throw new Error(`GET hostname: ${JSON.stringify(data)}`);
    return data.result;
}

async function updateHostnameDnslink(zoneId, token, hostnameId, dnslink) {
    const res = await fetch(`${CF_API}/zones/${zoneId}/web3/hostnames/${hostnameId}`, {
        method: "PATCH",
        headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
        body: JSON.stringify({ dnslink }),
    });
    if (!res.ok) throw new Error(`PATCH hostname: ${res.status} ${await res.text()}`);
    const data = await res.json();
    if (!data.success) throw new Error(`PATCH hostname: ${JSON.stringify(data)}`);
    return data.result;
}

async function validateCloudflare() {
    if (!CLOUDFLARE_ZONE_ID || !CLOUDFLARE_API_TOKEN) {
        console.log("Cloudflare: skip (CLOUDFLARE_ZONE_ID / CLOUDFLARE_API_TOKEN not set)");
        return;
    }
    try {
        console.log("Cloudflare: 1/5 Token verify...");
        const verify = await verifyCloudflareToken(CLOUDFLARE_API_TOKEN);
        console.log("Cloudflare: token valid (status:", verify.status + ")");

        console.log("Cloudflare: 2/5 List zones...");
        const zones = await listZones(CLOUDFLARE_API_TOKEN);
        const zoneIds = zones.map((z) => z.id);
        const zoneNames = zones.map((z) => `${z.name} (${z.id})`).join(", ");
        if (!zoneIds.includes(CLOUDFLARE_ZONE_ID)) {
            console.error(
                "Cloudflare: 403 usually means the zone ID is wrong for this token.\n" +
                    "  Your CLOUDFLARE_ZONE_ID: " +
                    CLOUDFLARE_ZONE_ID +
                    "\n  Zones this token can access: " +
                    zoneNames +
                    "\n  Use one of the IDs above as CLOUDFLARE_ZONE_ID."
            );
            throw new Error("CLOUDFLARE_ZONE_ID does not match any zone this token can access");
        }

        console.log("Cloudflare: 3/5 List Web3 hostnames (GET /zones/:zone_id/web3/hostnames)...");
        const hostnames = await listWeb3Hostnames(CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN);
        console.log("Cloudflare: OK (list Web3 hostnames, count:", hostnames.length + ")");
        const byName = new Map(hostnames.map((h) => [h.name, h]));
        for (const name of [MAINNET_HOSTNAME, TESTNET_HOSTNAME]) {
            if (byName.has(name)) {
                const h = byName.get(name);
                console.log(`  ${name}: id=${h.id}, dnslink=${h.dnslink ?? "(none)"}`);
            } else {
                console.log(`  ${name}: not found in zone`);
            }
        }

        if (testWrite) {
            for (const name of [MAINNET_HOSTNAME, TESTNET_HOSTNAME]) {
                if (!byName.has(name)) continue;
                const id = byName.get(name).id;
                console.log(`Cloudflare: 4/5 GET hostname (GET /zones/:zone_id/web3/hostnames/${id})...`);
                const current = await getWeb3Hostname(CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN, id);
                const dnslink = current.dnslink || "/ipfs/";
                console.log(`Cloudflare: 5/5 PATCH hostname (same dnslink, no-op)...`);
                await updateHostnameDnslink(CLOUDFLARE_ZONE_ID, CLOUDFLARE_API_TOKEN, id, dnslink);
                console.log(`  PATCH ${name} with same dnslink: OK (write permission verified, no change)`);
            }
        }
    } catch (err) {
        console.error("Cloudflare: FAIL -", err.message || err);
        throw err;
    }
}

async function main() {
    console.log("Validating API keys (read-only unless --test-write)\n");
    if (!pinataOnly) await validateCloudflare();
    if (!cloudflareOnly) await validatePinata();
    console.log("\nAll requested checks passed.");
}

main().catch((err) => {
    process.exit(1);
});
