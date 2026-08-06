/**
 * @fileoverview Fixture builders for the registry script tests.
 *
 * Registry documents are small enough to build inline, which keeps each test's input visible next
 * to its assertions instead of in a separate JSON file.
 */

/**
 * Builds a contract entry. `address: null` produces a tombstone.
 */
export function contract(address, blockNumber = 100, txHash = "0xtx") {
    return address === null
        ? { address: null, blockNumber: null, txHash: null }
        : { address, blockNumber, txHash };
}

/**
 * Builds a chain entry from a { name: address | entry } map.
 */
export function chain(contracts, extra = {}) {
    const built = {};
    for (const [name, value] of Object.entries(contracts)) {
        built[name] = typeof value === "object" && value !== null ? value : contract(value);
    }
    return { contracts: built, ...extra };
}

/**
 * Builds a registry layer.
 *
 * @param {Object} opts
 * @param {string|null} [opts.version] - Layer version; null models a patch layer
 * @param {Object} [opts.chains] - chainId → chain entry
 * @param {string|null} [opts.previousCid] - previousRegistry.ipfsHash; omit for a base snapshot
 * @param {string} [opts.previousVersion]
 * @param {Object|null} [opts.previousRegistry] - Set explicitly to model a malformed pointer
 * @param {string|null} [opts.network] - Declared network; null omits the field entirely, modelling
 *        a layer published before it existed
 */
export function layer({
    version = "v1",
    chains = {},
    previousCid,
    previousVersion = "v0",
    previousRegistry,
    network = "mainnet",
}) {
    const doc = { version, chains, deploymentInfo: { gitCommit: "abc123" } };
    if (network !== null) doc.network = network;
    if (previousRegistry !== undefined) {
        doc.previousRegistry = previousRegistry;
    } else if (previousCid) {
        doc.previousRegistry = { version: previousVersion, ipfsHash: previousCid };
    } else {
        doc.previousRegistry = null;
    }
    return doc;
}

/**
 * Builds a fetch-shaped function serving documents by CID, with failure injection.
 *
 * @param {Object} cidMap - CID → document (or Error to throw for that CID)
 * @param {Object} [options]
 * @param {string[]} [options.failGateways] - Gateway substrings that always fail
 * @param {number} [options.failStatus] - Status returned by failing gateways (default 500)
 * @returns {{fetchImpl: Function, calls: string[]}}
 */
export function fakeFetch(cidMap, options = {}) {
    const { failGateways = [], failStatus = 500 } = options;
    const calls = [];

    async function fetchImpl(url) {
        calls.push(url);

        if (failGateways.some((gateway) => url.includes(gateway))) {
            return { ok: false, status: failStatus, statusText: "Injected failure" };
        }

        const cid = url.split("/").pop();
        const document = cidMap[cid];
        if (document instanceof Error) throw document;
        if (!document) return { ok: false, status: 404, statusText: "Not Found" };

        return { ok: true, status: 200, json: async () => structuredClone(document) };
    }

    return { fetchImpl, calls };
}
