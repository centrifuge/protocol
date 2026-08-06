/**
 * @fileoverview Reconstructs the accumulated (flattened) state of the published registry chain.
 *
 * Published registries are a linked list: each layer carries only the contracts that changed
 * in that publish and points at its predecessor via `previousRegistry.ipfsHash`. Indexers walk
 * that list and merge layers to obtain the effective state of every contract.
 *
 * Delta generation has to compare against that same effective state. Comparing against the tip
 * document alone treats every contract the tip happens not to carry as "new", which inflates the
 * delta to a near-full snapshot and — because the next run then compares against that large
 * layer — makes successive publishes oscillate between complementary halves of the contract set.
 *
 * Usage:
 *   const { accumulated } = await collectRegistryChain(tipRegistry, { expectedNetwork: "mainnet" });
 *   // accumulated: { [chainId]: { contracts, ... } }
 *
 * `collectRegistryChain` is the entry point to prefer: it returns the accumulated state already
 * flattened, so callers never have to know that `flattenRegistryChain` requires oldest → newest
 * ordering (feeding it the other way round silently yields stale winners).
 *
 * Network I/O (gateways, layer cache) lives in ./registry-fetch.js.
 */

import { fetchRegistryFromIpfs, isRegistryDocument } from "./registry-fetch.js";

// Chain length guard. Cycles are caught precisely by the `seen` set below, so this only bounds
// how many fetches a single run may do. Keep it well clear of real chain lengths — the published
// chain grows by one layer per publish and testnet is already ~50 layers deep — because hitting
// this guard fails generation rather than silently truncating the comparison.
const DEFAULT_MAX_DEPTH = 500;

/**
 * Walks the registry linked list backwards from a tip document, collecting every layer.
 *
 * The walk terminates cleanly at the base snapshot (a layer with no `previousRegistry`).
 * Any other stop — a broken pointer, an unfetchable layer, a cycle, or the depth guard — leaves
 * the chain incomplete, which callers must treat as "cannot compute a trustworthy delta".
 *
 * @param {Object} tipRegistry - Already-fetched newest registry document
 * @param {Object} [options]
 * @param {number} [options.maxDepth] - Maximum number of layers to hold, tip included. A chain of
 *        exactly maxDepth layers still completes; only one longer than that is refused.
 * @param {string} [options.expectedNetwork] - "mainnet" | "testnet". When set, every layer must
 *        declare this network; see networkMismatchReason for why that matters.
 * @param {(msg: string) => void} [options.log] - Progress logger
 * @param {Object} [options.fetchOptions] - Passed to fetchRegistryFromIpfs (fetchImpl, cacheDir, …)
 * @returns {Promise<{layers: Object[], accumulated: Object, accumulatedAbis: Set<string>,
 *          complete: boolean, reason: string|null, fatal: boolean}>} `layers` is ordered oldest →
 *          newest; `accumulated` is those layers already flattened, and `accumulatedAbis` the ABI
 *          names they publish between them. `fatal` marks a chain that is not merely incomplete but
 *          invalid, so no "proceed anyway" override may apply — see networkMismatchReason.
 */
export async function collectRegistryChain(tipRegistry, options = {}) {
    const {
        maxDepth = DEFAULT_MAX_DEPTH,
        expectedNetwork = null,
        log = () => {},
        fetchOptions = {},
    } = options;

    const layers = [tipRegistry];
    const seen = new Set();
    let current = tipRegistry;
    let complete = false;

    // The tip is checked before walking: it comes from the caller — the live HTTP endpoint, or a
    // hand-supplied SOURCE_IPFS — so it is both the layer no gateway shape check has seen and the
    // one most likely to be from the wrong network. There is no point walking a chain we reject.
    let reason = tipRejectionReason(tipRegistry, expectedNetwork);
    let fatal = reason != null;

    // Keep walking while nothing has gone wrong. The terminal check comes before the depth bound,
    // so a chain whose base snapshot is the maxDepth'th layer is reported complete rather than
    // "too long": the bound limits how many layers may be held, not how many may be inspected.
    while (!reason) {
        if (!current.previousRegistry) {
            complete = true; // base snapshot reached
            break;
        }

        const previousCid = current.previousRegistry.ipfsHash;
        if (!previousCid) {
            reason =
                `layer ${describeLayer(current)} points at previous version ` +
                `"${current.previousRegistry.version ?? "unknown"}" but carries no previousRegistry.ipfsHash`;
            break;
        }
        if (seen.has(previousCid)) {
            reason = `cycle detected — ${previousCid} appears twice in the chain`;
            break;
        }
        if (layers.length >= maxDepth) {
            reason = `chain longer than maxDepth ${maxDepth} — refusing to keep walking`;
            break;
        }
        seen.add(previousCid);

        let previous;
        try {
            previous = await fetchRegistryFromIpfs(previousCid, { log, ...fetchOptions });
        } catch (error) {
            reason = error.message;
            break;
        }

        // Checked before the layer joins `layers`, so a foreign layer never reaches the
        // accumulated state even though the walk is about to be reported incomplete.
        const mismatch = networkMismatchReason(previous, expectedNetwork);
        if (mismatch) {
            reason = mismatch;
            fatal = true;
            break;
        }

        layers.push(previous);
        current = previous;
    }

    // A cross-network chain yields nothing usable: returning an empty state means that even a
    // caller which ignored `fatal` cannot end up comparing against the wrong environment.
    if (fatal) return { layers: [], accumulated: {}, accumulatedAbis: new Set(), complete: false, reason, fatal };

    layers.reverse(); // oldest → newest
    return {
        layers,
        accumulated: flattenRegistryChain(layers),
        accumulatedAbis: flattenRegistryAbis(layers),
        complete,
        reason,
        fatal,
    };
}

/**
 * Reports why the tip cannot be walked, or null if it is usable.
 *
 * Layers fetched from a gateway are shape-checked by `fetchRegistryFromIpfs`; the tip is not, so it
 * is checked here. Both rejections are fatal: an unvalidated tip flattens to an empty accumulated
 * state, which reads as "nothing is published yet" and inflates the delta into a full snapshot —
 * exactly what no override should be able to wave through.
 *
 * @param {Object} tip - Registry document handed in by the caller
 * @param {string|null} expectedNetwork - Network being generated, or null to skip that check
 * @returns {string|null}
 */
function tipRejectionReason(tip, expectedNetwork) {
    if (!isRegistryDocument(tip)) return `tip document is not a registry (no "chains" object)`;
    return networkMismatchReason(tip, expectedNetwork);
}

/**
 * Reports why a layer does not belong to the network being generated, or null if it is fine.
 *
 * Nothing in the chain format ties a layer to a network, so a mistyped `SOURCE_IPFS` pointing at
 * the other environment's CID would otherwise flatten that environment's contracts into this
 * delta and pass every downstream check — the delta invariants included, since they compare
 * against this same accumulated state.
 *
 * A layer with no `network` field is treated as unknown rather than wrong: every layer published
 * so far carries one, but refusing to walk an older base snapshot that predates the field would
 * turn a missing label into a hard generation failure.
 *
 * A mismatch is reported as `fatal` because, unlike an unreachable gateway, it is never something
 * to proceed through — `ALLOW_PARTIAL_REGISTRY_CHAIN=1` must not be able to wave it away.
 *
 * @param {Object} layer - Registry document
 * @param {string|null} expectedNetwork - Network the caller is generating, or null to skip
 * @returns {string|null} Diagnostic for `reason`, or null when there is no mismatch
 */
function networkMismatchReason(layer, expectedNetwork) {
    if (!expectedNetwork) return null;
    const declared = layer?.network;
    if (typeof declared !== "string") return null;
    if (declared === expectedNetwork) return null;
    return (
        `layer ${describeLayer(layer)} declares network "${declared}", ` +
        `but "${expectedNetwork}" is being generated — refusing to mix environments`
    );
}

/**
 * Merges registry layers into the accumulated contract state an indexer would hold.
 *
 * Later layers win, so a contract redeployed several times resolves to its newest entry and a
 * tombstone (`address: null`) published later correctly shadows the live entry before it.
 *
 * @param {Object[]} layers - Registry documents ordered oldest → newest
 * @returns {Object} Map of chainId → { network, adapters, contracts } with merged contracts
 */
export function flattenRegistryChain(layers) {
    const accumulated = {};

    for (const layer of layers) {
        for (const [chainId, chainData] of Object.entries(layer?.chains || {})) {
            const target = (accumulated[chainId] ??= { contracts: {} });

            // Newest layer that carries these fields wins; they are metadata only (the delta
            // comparison reads `contracts`), but keeping them makes the state self-describing.
            if (chainData.network) target.network = chainData.network;
            if (chainData.adapters) target.adapters = chainData.adapters;

            Object.assign(target.contracts, chainData.contracts || {});
        }
    }

    return accumulated;
}

/**
 * Collects every ABI name published anywhere in the chain.
 *
 * Presence, not freshness: an indexer walking the chain resolves a contract's ABI from whichever
 * layer last carried it, so a name published once stays available. This is what makes it possible
 * to tell a contract whose ABI the chain already has from one whose ABI was never shipped —
 * see the ABI-gap healing in ./registry-delta.js.
 *
 * @param {Object[]} layers - Registry documents in any order
 * @returns {Set<string>} Artifact basenames present in some layer's `abis`
 */
export function flattenRegistryAbis(layers) {
    const names = new Set();
    for (const layer of layers) {
        for (const name of Object.keys(layer?.abis || {})) names.add(name);
    }
    return names;
}

/**
 * Counts chains and contracts in an accumulated state, for logging.
 *
 * @param {Object} accumulated - Output of flattenRegistryChain
 * @returns {{chains: number, contracts: number}}
 */
export function summarizeAccumulatedState(accumulated) {
    const chains = Object.keys(accumulated).length;
    const contracts = Object.values(accumulated).reduce(
        (sum, chain) => sum + Object.keys(chain.contracts || {}).length,
        0
    );
    return { chains, contracts };
}

/**
 * Human-readable label for a registry layer, used in diagnostics.
 */
function describeLayer(registry) {
    const version = registry?.version || registry?.deploymentInfo?.gitCommit;
    return version ? `"${version}"` : "(unversioned patch)";
}
