import { test } from "node:test";
import assert from "node:assert/strict";

import { computeChainDelta, hasContractChanged } from "../utils/registry-delta.js";
import { flattenRegistryChain } from "../utils/registry-chain.js";
import { chain, contract, layer } from "./helpers.js";

test("hasContractChanged treats everything as new when nothing is published for the chain", () => {
    assert.equal(hasContractChanged("hub", contract("0xhub"), null), true);
    assert.equal(hasContractChanged("hub", contract("0xhub"), {}), true);
});

test("hasContractChanged flags a contract absent from the published state", () => {
    const published = chain({ spoke: "0xspoke" });
    assert.equal(hasContractChanged("hub", contract("0xhub"), published), true);
});

test("hasContractChanged flags a new address and ignores case differences", () => {
    const published = chain({ hub: "0xAAA" });
    assert.equal(hasContractChanged("hub", contract("0xBBB"), published), true);
    assert.equal(hasContractChanged("hub", contract("0xaaa"), published), false);
});

test("hasContractChanged flags a redeploy at the same address via blockNumber", () => {
    const published = chain({ hub: contract("0xhub", 100) });
    assert.equal(hasContractChanged("hub", contract("0xhub", 200), published), true);
    assert.equal(hasContractChanged("hub", contract("0xhub", 100), published), false);
});

test("hasContractChanged flags a blockNumber env has and the chain never carried", () => {
    // Explorer lookups fill blockNumbers in after the fact. Requiring both sides to have one meant
    // the backfill could never reach the chain, leaving the indexer to start that contract's
    // listener from the chain-level startBlock forever.
    const published = chain({ hub: { address: "0xhub", blockNumber: null, txHash: null } });

    assert.equal(hasContractChanged("hub", contract("0xhub", 100), published), true);
});

test("hasContractChanged ignores env dropping a blockNumber the chain has", () => {
    // The entry would be emitted with blockNumber null, and the indexer's merge takes leaf nulls
    // literally — so restating it would erase a published blockNumber rather than correct it.
    const published = chain({ hub: contract("0xhub", 100) });
    const envWithoutBlock = { address: "0xhub", blockNumber: null, txHash: null };

    assert.equal(hasContractChanged("hub", envWithoutBlock, published), false);
});

test("hasContractChanged handles bare address strings on either side", () => {
    assert.equal(hasContractChanged("hub", "0xhub", { contracts: { hub: "0xhub" } }), false);
    assert.equal(hasContractChanged("hub", "0xother", { contracts: { hub: "0xhub" } }), true);
});

test("computeChainDelta includes only contracts that actually changed", () => {
    const published = chain({ hub: contract("0xhub", 100), spoke: contract("0xspoke", 100) });
    const env = {
        hub: contract("0xhub", 100), // unchanged
        spoke: contract("0xspokeV2", 200), // redeployed
        vault: contract("0xvault", 300), // new
    };

    const { changed, deprecated } = computeChainDelta(env, published);

    assert.deepEqual([...changed].sort(), ["spoke", "vault"]);
    assert.deepEqual(deprecated, {});
});

test("computeChainDelta tombstones a published contract dropped from env", () => {
    const published = chain({ hub: "0xhub", guardian: "0xguardian" });

    const { deprecated } = computeChainDelta({ hub: contract("0xhub") }, published);

    assert.deepEqual(deprecated, { guardian: { address: null, blockNumber: null, txHash: null } });
});

test("computeChainDelta does not re-tombstone a contract already retired in the chain", () => {
    // The tombstone was published in an earlier layer, so the flattened state carries address null.
    const published = flattenRegistryChain([
        layer({ chains: { 1: chain({ hub: "0xhub", guardian: "0xguardian" }) } }),
        layer({ chains: { 1: chain({ guardian: contract(null) }) } }),
    ])["1"];

    const { deprecated } = computeChainDelta({ hub: contract("0xhub") }, published);

    assert.deepEqual(deprecated, {}, "a tombstone is published once, not on every run");
});

test("computeChainDelta tombstones a contract retired several layers back", () => {
    // The regression that hid deprecations: guardian was last seen live two layers before the tip,
    // so comparing against the tip alone would never notice it is gone from env.
    const accumulated = flattenRegistryChain([
        layer({ version: "v1", chains: { 1: chain({ hub: "0xhub", guardian: "0xguardian" }) } }),
        layer({ version: "v2", chains: { 1: chain({ spoke: "0xspoke" }) } }),
        layer({ version: "v3", chains: { 1: chain({ vault: "0xvault" }) } }),
    ])["1"];

    const { deprecated } = computeChainDelta(
        { hub: contract("0xhub"), spoke: contract("0xspoke"), vault: contract("0xvault") },
        accumulated
    );

    assert.deepEqual(Object.keys(deprecated), ["guardian"]);
});

test("computeChainDelta against the flattened chain emits nothing when env already matches (regression)", () => {
    // This is the original bug in miniature. The published chain holds hub+spoke+vault, but the tip
    // layer carries only vault. Comparing against the tip re-emits hub and spoke as "new" — a delta
    // that is really a snapshot, whose complement then becomes the next run's baseline, which is
    // what made published layers oscillate 443/12/443/12. Against the flattened chain, a run with
    // no env changes must emit nothing at all.
    const layers = [
        layer({ version: "v1", chains: { 1: chain({ hub: "0xhub", spoke: "0xspoke" }) } }),
        layer({ version: "v2", chains: { 1: chain({ vault: "0xvault" }) } }),
    ];
    const env = {
        hub: contract("0xhub"),
        spoke: contract("0xspoke"),
        vault: contract("0xvault"),
    };

    const tipOnly = computeChainDelta(env, layers[layers.length - 1].chains["1"]);
    assert.deepEqual([...tipOnly.changed].sort(), ["hub", "spoke"], "tip-only comparison inflates");

    const flattened = computeChainDelta(env, flattenRegistryChain(layers)["1"]);
    assert.equal(flattened.changed.size, 0, "flattened comparison emits nothing");
    assert.deepEqual(flattened.deprecated, {});
});

test("computeChainDelta treats a tombstoned contract that env re-adds as changed", () => {
    const accumulated = flattenRegistryChain([
        layer({ chains: { 1: chain({ oracleValuation: "0xv1" }) } }),
        layer({ chains: { 1: chain({ oracleValuation: contract(null) }) } }),
    ])["1"];

    const { changed, deprecated } = computeChainDelta({ oracleValuation: contract("0xv2") }, accumulated);

    assert.deepEqual([...changed], ["oracleValuation"]);
    assert.deepEqual(deprecated, {});
});

test("computeChainDelta re-emits an unchanged contract whose ABI the chain never carried", () => {
    // The regression this guards: while deltas were computed against the tip alone, an ABI gap
    // healed by accident because nearly everything counted as changed. Comparing against the
    // accumulated state removed that accident, so the gap has to be closed deliberately.
    const published = chain({ tokenBridge: contract("0xbridge", 100), hub: contract("0xhub", 100) });
    const env = { tokenBridge: contract("0xbridge", 100), hub: contract("0xhub", 100) };

    const { changed, abiGaps } = computeChainDelta(env, published, {
        publishedAbiNames: new Set(["Hub"]),
        abiNamesForContract: (key) => [key.charAt(0).toUpperCase() + key.slice(1)],
    });

    assert.deepEqual([...changed], ["tokenBridge"]);
    assert.deepEqual([...abiGaps], ["tokenBridge"]);
});

test("computeChainDelta leaves unchanged contracts alone when the chain has their ABIs", () => {
    const published = chain({ hub: contract("0xhub", 100) });
    const env = { hub: contract("0xhub", 100) };

    const { changed, abiGaps } = computeChainDelta(env, published, {
        publishedAbiNames: new Set(["Hub"]),
        abiNamesForContract: (key) => [key.charAt(0).toUpperCase() + key.slice(1)],
    });

    assert.equal(changed.size, 0);
    assert.equal(abiGaps.size, 0);
});

test("computeChainDelta skips ABI-gap detection when no coverage is supplied", () => {
    const published = chain({ hub: contract("0xhub", 100) });

    const { changed, abiGaps } = computeChainDelta({ hub: contract("0xhub", 100) }, published);

    assert.equal(changed.size, 0, "an unknown chain must not force everything into the delta");
    assert.equal(abiGaps.size, 0);
});

test("computeChainDelta counts an ABI gap once, not twice, for an already-changed contract", () => {
    const published = chain({ hub: contract("0xold", 100) });
    const env = { hub: contract("0xnew", 200) };

    const { changed, abiGaps } = computeChainDelta(env, published, {
        publishedAbiNames: new Set(),
        abiNamesForContract: () => ["Hub"],
    });

    assert.deepEqual([...changed], ["hub"]);
    assert.equal(abiGaps.size, 0, "already changed on its own merits, not an ABI-gap heal");
});
