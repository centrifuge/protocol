/**
 * @fileoverview Endpoints and network I/O for published registries.
 *
 * Every script that reads a published registry goes through here: the live HTTP endpoints, the
 * dnslink CID resolution, and the multi-gateway IPFS fetch with its on-disk cache. Keeping one
 * copy matters because the gateway list rots (cloudflare-ipfs.com was retired in 2024) and a
 * script left holding a stale copy fails in a way that looks like IPFS being down.
 *
 * Published layers are content-addressed, so a CID's contents can never change. Fetches are
 * therefore cached under `cache/registry-chain/<cid>.json` forever — without it, a chain walk
 * re-fetches every layer on every run (testnet is ~48 layers) and public gateways rate-limit.
 */

import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "fs";
import { join } from "path";
import { resolveTxt } from "dns/promises";

/** Live HTTP endpoints serving the tip of each chain. */
export const REGISTRY_URLS = {
    mainnet: "https://registry.centrifuge.io",
    testnet: "https://registry.testnet.centrifuge.io",
};

/**
 * DNS hostnames for dnslink CID resolution. Cloudflare Web3 hostnames publish a TXT record at
 * _dnslink.<hostname> with value "dnslink=/ipfs/<CID>".
 */
export const DNSLINK_HOSTNAMES = {
    mainnet: "registry.centrifuge.io",
    testnet: "registry.testnet.centrifuge.io",
};

/**
 * IPFS gateways to try, in order. Centrifuge's dedicated Pinata gateway first (registries are
 * pinned to that account, so it serves them without the public rate limits), then the shared
 * Pinata gateway and public fallbacks so one gateway's weather cannot truncate a chain walk.
 */
export const IPFS_GATEWAYS = [
    "https://centrifuge-files.mypinata.cloud/ipfs/",
    "https://gateway.pinata.cloud/ipfs/",
    "https://ipfs.io/ipfs/",
    "https://dweb.link/ipfs/",
];

const FETCH_TIMEOUT_MS = 20000;

/** Cache directory for fetched layers, relative to the repo root. */
const DEFAULT_CACHE_DIR = join("cache", "registry-chain");

/**
 * Resolves the cache directory for IPFS layers, or null when caching is disabled.
 *
 * @returns {string|null}
 */
export function resolveLayerCacheDir() {
    if (process.env.REGISTRY_CHAIN_NO_CACHE === "1") return null;
    return process.env.REGISTRY_CHAIN_CACHE_DIR || DEFAULT_CACHE_DIR;
}

/**
 * Validates that a string is a valid IPFS hash (CID). Supports v0 (Qm...) and v1 (baf...).
 *
 * @param {string} input - String to validate
 * @returns {boolean} True if input is a valid IPFS CID
 */
export function isValidIpfsHash(input) {
    if (!input || typeof input !== "string") return false;

    // v0: Qm followed by 44 base58 characters (base58 excludes 0, O, I, l).
    // v1: baf followed by 50+ base32 characters; kept permissive to tolerate other encodings.
    const base58Char = "[1-9A-HJ-NP-Za-km-z]";
    const cidV0Pattern = new RegExp(`^Qm${base58Char}{44}$`);
    const cidV1Pattern = /^baf[a-z0-9]{50,}$/i;

    return cidV0Pattern.test(input) || cidV1Pattern.test(input);
}

/**
 * Reports whether a CID is a plain path segment, safe to interpolate into a gateway URL and a cache
 * filename.
 *
 * Not every CID reaching the fetch is hand-supplied: chain pointers come out of published documents
 * and the live CID out of a DNS record, neither of which this repo controls. Real CIDs are
 * alphanumeric, so requiring a single segment costs nothing and keeps a value carrying path
 * separators from reading or writing outside the layer cache.
 *
 * @param {unknown} cid - Candidate CID
 * @returns {boolean} True if the CID can be used as a URL segment and cache filename
 */
export function isPlainCid(cid) {
    return typeof cid === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(cid);
}

/**
 * Reads a cached layer, or null on a miss. A corrupt file — or one written before the shape check
 * existed — is treated as a miss so it can never poison later runs.
 */
function readCachedLayer(cacheDir, cid) {
    const path = join(cacheDir, `${cid}.json`);
    if (!existsSync(path)) return null;
    try {
        const cached = JSON.parse(readFileSync(path, "utf8"));
        return isRegistryDocument(cached) ? cached : null;
    } catch {
        return null;
    }
}

/**
 * Writes a layer to the cache. Via a temp file plus rename, so a crashed or concurrent run cannot
 * leave a half-written document behind. Cache failures are never fatal — the fetch already
 * succeeded.
 */
function writeCachedLayer(cacheDir, cid, document) {
    try {
        mkdirSync(cacheDir, { recursive: true });
        const path = join(cacheDir, `${cid}.json`);
        const tmp = `${path}.${process.pid}.tmp`;
        writeFileSync(tmp, JSON.stringify(document));
        renameSync(tmp, path);
    } catch {
        // Caching is an optimization; a read-only or full filesystem must not fail generation.
    }
}

/**
 * Minimal shape check for a fetched registry layer.
 *
 * Deliberately narrow: `chains` is the only field every layer shape (delta, patch, full) must
 * carry, and it is the field the accumulated state is built from.
 *
 * @param {unknown} document - Parsed JSON from a gateway or the layer cache
 * @returns {boolean} True if the document can be treated as a registry layer
 */
export function isRegistryDocument(document) {
    return (
        document != null &&
        typeof document === "object" &&
        !Array.isArray(document) &&
        typeof document.chains === "object" &&
        document.chains !== null &&
        !Array.isArray(document.chains)
    );
}

/**
 * Fetches a single registry document from IPFS, trying each gateway in turn.
 *
 * @param {string} cid - IPFS CID of the registry document
 * @param {Object} [options]
 * @param {typeof fetch} [options.fetchImpl] - Injectable fetch, for tests
 * @param {string[]} [options.gateways] - Gateway prefixes to try, in order
 * @param {number} [options.timeoutMs] - Per-gateway timeout
 * @param {string|null} [options.cacheDir] - Layer cache directory; null disables caching
 * @param {(msg: string) => void} [options.log] - Progress logger
 * @returns {Promise<Object>} Parsed registry JSON
 * @throws {Error} If every gateway fails
 */
export async function fetchRegistryFromIpfs(cid, options = {}) {
    const {
        fetchImpl = fetch,
        gateways = IPFS_GATEWAYS,
        timeoutMs = FETCH_TIMEOUT_MS,
        cacheDir = resolveLayerCacheDir(),
        log = () => {},
    } = options;

    // Before the cache is touched and before any gateway is contacted: the CID becomes both a
    // filesystem path and a URL below, and a chain pointer is only as trustworthy as the layer
    // carrying it.
    if (!isPlainCid(cid)) {
        throw new Error(`${JSON.stringify(cid)} is not a plain CID — refusing to fetch it`);
    }

    if (cacheDir) {
        const cached = readCachedLayer(cacheDir, cid);
        if (cached) {
            log(`  Layer ${cid} — cache hit`);
            return cached;
        }
    }

    const failures = [];

    for (const gateway of gateways) {
        const url = `${gateway}${cid}`;
        try {
            const response = await fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs) });
            if (!response.ok) {
                failures.push(`${gateway} → ${response.status} ${response.statusText}`);
                // Nothing reads an error page, but leaving it undrained holds the socket out of
                // the keep-alive pool for the rest of the walk.
                await discardBody(response);
                continue;
            }
            const document = await response.json();
            // A gateway can serve anything for a CID (an error page rendered as JSON, a
            // different pinned file). Reject non-registry documents here so they neither enter
            // the layer cache nor get flattened as an empty layer — which would silently
            // understate the published state and inflate the delta.
            if (!isRegistryDocument(document)) {
                failures.push(`${gateway} → served a document with no "chains" object`);
                continue;
            }
            log(`  Layer ${cid} — fetched from ${gateway}`);
            if (cacheDir) writeCachedLayer(cacheDir, cid, document);
            return document;
        } catch (error) {
            failures.push(`${gateway} → ${error.message}`);
        }
    }

    throw new Error(`could not fetch ${cid} from any gateway (${failures.join("; ")})`);
}

/**
 * Releases a response body we are not going to read. Tolerates test doubles and bodyless
 * responses, and never throws — a body being discarded is not worth failing a fetch over.
 *
 * @param {Object} response - Response (or stand-in) whose body should be released
 */
async function discardBody(response) {
    try {
        await response.body?.cancel?.();
    } catch {
        // Already errored or consumed; nothing to release.
    }
}

/**
 * Resolves the IPFS CID of the currently live registry via DNS TXT lookup. This is the source of
 * truth — the dnslink record points to whatever CID Cloudflare is actually serving.
 *
 * @param {string} environment - "mainnet" or "testnet"
 * @param {Object} [options]
 * @param {(msg: string) => void} [options.log] - Progress logger
 * @returns {Promise<string|null>} IPFS CID or null if not resolvable
 */
export async function resolveLiveCid(environment, options = {}) {
    const { log = console.log } = options;
    const hostname = DNSLINK_HOSTNAMES[environment];
    if (!hostname) return null;

    const dnslinkHost = `_dnslink.${hostname}`;
    try {
        log(`  Resolving live CID via DNS: ${dnslinkHost}`);
        const records = await resolveTxt(dnslinkHost);
        // records is an array of arrays of strings, e.g. [["dnslink=/ipfs/Qm..."]]
        for (const record of records) {
            const match = record.join("").match(/^dnslink=\/ipfs\/(.+)$/);
            if (match) {
                log(`  ✓ Resolved live CID: ${match[1]}`);
                return match[1];
            }
        }
        console.warn(`  ⚠ No dnslink record found at ${dnslinkHost}`);
        return null;
    } catch (error) {
        console.warn(`  ⚠ DNS lookup failed for ${dnslinkHost}: ${error.message}`);
        return null;
    }
}

/**
 * Fetches the live registry tip for an environment.
 *
 * The HTTP endpoint is tried first because it is what consumers read. If it is unreachable the
 * dnslink CID is resolved and fetched through the gateways instead, so a Cloudflare outage does
 * not look like "no registry published".
 *
 * @param {string} environment - "mainnet" or "testnet"
 * @param {Object} [options] - Passed through to fetchRegistryFromIpfs on the fallback path
 * @param {typeof fetch} [options.fetchImpl] - Injectable fetch, for tests
 * @returns {Promise<Object|null>} The live registry, or null if it cannot be read
 */
export async function fetchLiveRegistry(environment, options = {}) {
    const { fetchImpl = fetch, log = console.log } = options;
    const url = REGISTRY_URLS[environment];
    if (!url) {
        console.warn(`No registry URL configured for environment: ${environment}`);
        return null;
    }

    try {
        log(`Fetching current registry from ${url}...`);
        const response = await fetchImpl(url, { signal: AbortSignal.timeout(FETCH_TIMEOUT_MS) });
        if (response.ok) {
            const document = await response.json();
            // The endpoint is a Cloudflare Web3 gateway: a 200 can still carry an error page or a
            // stale non-registry document. Treat that like an unreachable endpoint so the dnslink
            // fallback below gets its turn, rather than walking a tip with no `chains`.
            if (isRegistryDocument(document)) return document;
            console.warn(`${url} served a document with no "chains" object — treating as unavailable`);
        } else {
            console.warn(`Failed to fetch registry: ${response.status} ${response.statusText}`);
        }
    } catch (error) {
        console.warn(`Could not fetch current registry from ${url}: ${error.message}`);
    }

    const cid = await resolveLiveCid(environment, { log });
    if (!cid) return null;

    try {
        console.warn(`  ⚠ Falling back to the dnslink CID ${cid} via IPFS`);
        return await fetchRegistryFromIpfs(cid, options);
    } catch (error) {
        console.warn(`  ⚠ Could not fetch the live registry from IPFS either: ${error.message}`);
        return null;
    }
}
