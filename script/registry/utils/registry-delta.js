/**
 * @fileoverview Decides what belongs in a delta: which env contracts changed, and which published
 * contracts have been retired.
 *
 * Both decisions are made against the *accumulated* published state — every layer of the chain
 * flattened (see ./registry-chain.js) — never against a single layer. A single layer carries only
 * its own changes, so comparing against one marks every contract it happens to omit as new, which
 * inflates the delta into a near-full snapshot and hides deprecations recorded further back.
 *
 * These live outside abi-registry.js so they can be tested without running the whole generator.
 */

/**
 * Reads the address off an env or registry contract entry, which may be a bare address string.
 */
function addressOf(entry) {
    return typeof entry === "string" ? entry : entry?.address;
}

/**
 * Reports whether a contract differs from what the published chain already carries.
 *
 * @param {string} contractName - Name of the contract (for symmetry with callers' logging)
 * @param {Object|string} localContract - Contract data from the local env file
 * @param {Object|null} accumulatedChain - Chain data merged across all registry layers; a single
 *        layer here would over-report changes
 * @returns {boolean} True if the contract is new or was redeployed
 */
export function hasContractChanged(contractName, localContract, accumulatedChain) {
    if (!accumulatedChain?.contracts) {
        return true; // Nothing published for this chain yet, so everything is new
    }

    const existingContract = accumulatedChain.contracts[contractName];
    if (!existingContract) {
        return true; // New contract
    }

    if (addressOf(localContract)?.toLowerCase() !== addressOf(existingContract)?.toLowerCase()) {
        return true;
    }

    // A blockNumber that differs at the same address means the entry was corrected or redeployed.
    // A blockNumber env has and the chain never carried counts too: explorer lookups fill these in
    // after the fact, and requiring both sides to have one meant such a backfill could never reach
    // the chain — the indexer would keep starting that contract's listener from the chain-level
    // startBlock instead.
    //
    // The reverse is deliberately not a change. Emitting an entry whose blockNumber is null would
    // overwrite the published number with null (the indexer's merge takes leaf nulls literally, as
    // tombstones rely on), so env dropping a blockNumber must not erase what is already published.
    const localBlock = localContract?.blockNumber;
    const existingBlock = existingContract.blockNumber;
    if (localBlock != null && String(localBlock) !== String(existingBlock)) {
        return true;
    }

    return false;
}

/**
 * Computes one chain's delta membership: which env contracts to include, and which published
 * contracts to tombstone.
 *
 * A contract is deprecated when the accumulated state still carries it live but the env file no
 * longer does (renamed, merged, or retired). Contracts a later layer already tombstoned are left
 * alone so a tombstone is published once rather than on every subsequent run.
 *
 * ABI gaps also force inclusion. `packAbis` can finish with "ABIs not found for: …" and still
 * publish, leaving a contract in the chain with no ABI anywhere. While deltas were computed against
 * the tip alone that healed by accident — nearly every contract counted as changed on every run, so
 * its ABI was re-shipped. Comparing against the accumulated state removed that accident, which
 * would make such a gap permanent. So an active contract whose ABI the chain never carried is
 * re-emitted even when its address is unchanged, purely to ship the missing ABI.
 *
 * @param {Object} envContracts - Contracts for this chain from env/*.json
 * @param {Object|null} accumulatedChain - Flattened published state for this chain
 * @param {Object} [options]
 * @param {Set<string>|null} [options.publishedAbiNames] - ABI names present anywhere in the chain
 *        (see flattenRegistryAbis). Omit to skip ABI-gap detection entirely.
 * @param {(contractKey: string) => string[]} [options.abiNamesForContract] - Artifact basenames a
 *        contract key requires; `artifactNamesForContractKey` from ./abi-cache.js in production
 * @returns {{changed: Set<string>, deprecated: Record<string, {address: null, blockNumber: null, txHash: null}>, abiGaps: Set<string>}}
 *          `abiGaps` ⊆ `changed`: entries included only to heal a missing ABI.
 */
export function computeChainDelta(envContracts, accumulatedChain, options = {}) {
    const { publishedAbiNames = null, abiNamesForContract = () => [] } = options;
    const changed = new Set();
    const abiGaps = new Set();
    const deprecated = {};
    const contracts = envContracts || {};

    for (const [contractName, contractData] of Object.entries(contracts)) {
        if (hasContractChanged(contractName, contractData, accumulatedChain)) {
            changed.add(contractName);
            continue;
        }
        // Unchanged — but if the chain has no ABI for it, it must ride along to carry one.
        if (!publishedAbiNames || addressOf(contractData) == null) continue;
        const missing = abiNamesForContract(contractName).filter((name) => !publishedAbiNames.has(name));
        if (missing.length > 0) {
            changed.add(contractName);
            abiGaps.add(contractName);
        }
    }

    for (const [contractName, published] of Object.entries(accumulatedChain?.contracts || {})) {
        if (published?.address === null) continue;
        if (contracts[contractName]) continue;
        deprecated[contractName] = { address: null, blockNumber: null, txHash: null };
    }

    return { changed, deprecated, abiGaps };
}
