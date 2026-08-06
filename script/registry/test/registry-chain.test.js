import { test } from "node:test";
import assert from "node:assert/strict";

import {
    collectRegistryChain,
    flattenRegistryAbis,
    flattenRegistryChain,
    summarizeAccumulatedState,
} from "../utils/registry-chain.js";
import { chain, contract, fakeFetch, layer } from "./helpers.js";

const noCache = { cacheDir: null };

test("flattenRegistryChain lets the newest layer win", () => {
    const accumulated = flattenRegistryChain([
        layer({ version: "v1", chains: { 1: chain({ hub: "0xold" }) } }),
        layer({ version: "v2", chains: { 1: chain({ hub: "0xnew" }) } }),
    ]);

    assert.equal(accumulated["1"].contracts.hub.address, "0xnew");
});

test("flattenRegistryChain accumulates contracts across layers that touch different chains", () => {
    const accumulated = flattenRegistryChain([
        layer({ chains: { 1: chain({ hub: "0xhub", spoke: "0xspoke" }) } }),
        layer({ chains: { 8453: chain({ hub: "0xbase" }) } }),
        layer({ chains: { 1: chain({ vault: "0xvault" }) } }),
    ]);

    // The bug this guards: a later layer touching only chain 1 must not erase chain 8453, and must
    // not erase chain 1's other contracts either.
    assert.deepEqual(Object.keys(accumulated).sort(), ["1", "8453"]);
    assert.deepEqual(Object.keys(accumulated["1"].contracts).sort(), ["hub", "spoke", "vault"]);
    assert.equal(summarizeAccumulatedState(accumulated).contracts, 4);
});

test("flattenRegistryChain lets a later tombstone shadow a live entry", () => {
    const accumulated = flattenRegistryChain([
        layer({ chains: { 1: chain({ guardian: "0xguardian" }) } }),
        layer({ chains: { 1: chain({ guardian: contract(null) }) } }),
    ]);

    assert.equal(accumulated["1"].contracts.guardian.address, null);
});

test("flattenRegistryChain resolves a contract re-added after a tombstone", () => {
    const accumulated = flattenRegistryChain([
        layer({ chains: { 1: chain({ oracleValuation: "0xv1" }) } }),
        layer({ chains: { 1: chain({ oracleValuation: contract(null) }) } }),
        layer({ chains: { 1: chain({ oracleValuation: "0xv2" }) } }),
    ]);

    assert.equal(accumulated["1"].contracts.oracleValuation.address, "0xv2");
});

test("flattenRegistryChain merges null-version patch layers like any other layer", () => {
    const accumulated = flattenRegistryChain([
        layer({ version: "v1", chains: { 1: chain({ hub: "0xhub" }) } }),
        layer({ version: null, chains: { 1: chain({ spoke: "0xspoke" }) } }),
    ]);

    assert.deepEqual(Object.keys(accumulated["1"].contracts).sort(), ["hub", "spoke"]);
});

test("flattenRegistryChain keeps the newest network and adapter metadata", () => {
    const accumulated = flattenRegistryChain([
        layer({
            chains: { 1: chain({ hub: "0xhub" }, { network: { chainId: 1, centrifugeId: 1 }, adapters: { axelar: {} } }) },
        }),
        layer({ chains: { 1: chain({ hub: "0xhub2" }, { network: { chainId: 1, centrifugeId: 99 } }) } }),
    ]);

    assert.equal(accumulated["1"].network.centrifugeId, 99);
    // A layer that does not restate adapters must not drop them.
    assert.deepEqual(accumulated["1"].adapters, { axelar: {} });
});

test("collectRegistryChain walks to the base snapshot and returns layers oldest to newest", async () => {
    const base = layer({ version: "v1", chains: { 1: chain({ hub: "0xhub" }) } });
    const middle = layer({ version: "v2", chains: { 1: chain({ spoke: "0xspoke" }) }, previousCid: "cidBase" });
    const tip = layer({ version: "v3", chains: { 1: chain({ vault: "0xvault" }) }, previousCid: "cidMiddle" });
    const { fetchImpl } = fakeFetch({ cidBase: base, cidMiddle: middle });

    const result = await collectRegistryChain(tip, { fetchOptions: { fetchImpl, ...noCache } });

    assert.equal(result.complete, true);
    assert.equal(result.reason, null);
    assert.deepEqual(result.layers.map((l) => l.version), ["v1", "v2", "v3"]);
});

test("collectRegistryChain reports a cycle instead of looping forever", async () => {
    const looping = layer({ version: "v2", chains: {}, previousCid: "cidLoop" });
    const { fetchImpl } = fakeFetch({ cidLoop: looping });
    const tip = layer({ version: "v3", chains: {}, previousCid: "cidLoop" });

    const result = await collectRegistryChain(tip, { fetchOptions: { fetchImpl, ...noCache } });

    assert.equal(result.complete, false);
    assert.match(result.reason, /cycle detected/);
});

test("collectRegistryChain reports a previousRegistry with no ipfsHash", async () => {
    const tip = layer({ version: "v2", chains: {}, previousRegistry: { version: "v1" } });

    const result = await collectRegistryChain(tip, { fetchOptions: { ...noCache } });

    assert.equal(result.complete, false);
    assert.match(result.reason, /no previousRegistry\.ipfsHash/);
});

test("collectRegistryChain reports an unfetchable layer with the gateway failures", async () => {
    const { fetchImpl } = fakeFetch({});
    const tip = layer({ version: "v2", chains: {}, previousCid: "cidMissing" });

    const result = await collectRegistryChain(tip, { fetchOptions: { fetchImpl, ...noCache } });

    assert.equal(result.complete, false);
    assert.match(result.reason, /could not fetch cidMissing/);
    assert.match(result.reason, /404/);
});

test("collectRegistryChain stops when a layer points at something that is not a CID", async () => {
    const { fetchImpl, calls } = fakeFetch({});
    const tip = layer({ version: "v2", chains: {}, previousCid: "../../etc/passwd" });

    const result = await collectRegistryChain(tip, { fetchOptions: { fetchImpl, ...noCache } });

    assert.equal(result.complete, false);
    assert.match(result.reason, /is not a plain CID/);
    assert.equal(calls.length, 0);
});

test("collectRegistryChain stops at maxDepth rather than walking indefinitely", async () => {
    // Every layer points at the next distinct CID, so only the depth guard can stop the walk.
    const documents = {};
    for (let i = 0; i < 10; i++) {
        documents[`cid${i}`] = layer({ version: `v${i}`, chains: {}, previousCid: `cid${i + 1}` });
    }
    const { fetchImpl } = fakeFetch(documents);
    const tip = layer({ version: "tip", chains: {}, previousCid: "cid0" });

    const result = await collectRegistryChain(tip, {
        maxDepth: 3,
        fetchOptions: { fetchImpl, ...noCache },
    });

    assert.equal(result.complete, false);
    assert.match(result.reason, /longer than maxDepth 3/);
    // maxDepth bounds how many layers are held, tip included.
    assert.equal(result.layers.length, 3);
});

test("collectRegistryChain completes when the base snapshot is the maxDepth'th layer", async () => {
    // The terminal check must run before the depth bound. Otherwise a chain of exactly maxDepth
    // layers is fetched in full, the base is in hand, and the walk still reports "chain longer
    // than maxDepth" — which would make setting the bound to the observed chain length fail.
    const base = layer({ version: "v1", chains: { 1: chain({ hub: "0xhub" }) } });
    const { fetchImpl } = fakeFetch({ cidBase: base });
    const tip = layer({ version: "v2", chains: {}, previousCid: "cidBase" });

    const result = await collectRegistryChain(tip, {
        maxDepth: 2,
        fetchOptions: { fetchImpl, ...noCache },
    });

    assert.equal(result.complete, true);
    assert.equal(result.reason, null);
    assert.equal(result.layers.length, 2);
});

test("collectRegistryChain survives a failing gateway by falling through to the next", async () => {
    const base = layer({ version: "v1", chains: { 1: chain({ hub: "0xhub" }) } });
    const { fetchImpl, calls } = fakeFetch({ cidBase: base }, { failGateways: ["centrifuge-files"] });
    const tip = layer({ version: "v2", chains: {}, previousCid: "cidBase" });

    const result = await collectRegistryChain(tip, { fetchOptions: { fetchImpl, ...noCache } });

    assert.equal(result.complete, true);
    assert.equal(result.layers.length, 2);
    assert.ok(calls.some((url) => url.includes("centrifuge-files")), "first gateway was tried");
    assert.ok(calls.length > 1, "fell through to a second gateway");
});

test("collectRegistryChain returns the accumulated state alongside the layers", async () => {
    // Callers take `accumulated` rather than ordering layers themselves: flattenRegistryChain
    // requires oldest → newest and silently returns stale winners if handed the reverse.
    const base = layer({ version: "v1", chains: { 1: chain({ hub: "0xold", guardian: "0xguardian" }) } });
    const { fetchImpl } = fakeFetch({ cidBase: base });
    const tip = layer({
        version: "v2",
        chains: { 1: chain({ hub: "0xnew", guardian: contract(null) }) },
        previousCid: "cidBase",
    });

    const result = await collectRegistryChain(tip, { fetchOptions: { fetchImpl, ...noCache } });

    assert.deepEqual(result.accumulated, flattenRegistryChain(result.layers));
    assert.equal(result.accumulated["1"].contracts.hub.address, "0xnew");
    assert.equal(result.accumulated["1"].contracts.guardian.address, null);
});

test("collectRegistryChain refuses a tip from the wrong network", async () => {
    // A mistyped SOURCE_IPFS pointing at the other environment would otherwise flatten that
    // environment's contracts into this delta, and pass every downstream check — the delta
    // invariants included, since they compare against this same accumulated state.
    const { fetchImpl } = fakeFetch({});
    const tip = layer({ version: "v2", network: "testnet", chains: { 1: chain({ hub: "0xhub" }) } });

    const result = await collectRegistryChain(tip, {
        expectedNetwork: "mainnet",
        fetchOptions: { fetchImpl, ...noCache },
    });

    assert.equal(result.complete, false);
    assert.match(result.reason, /declares network "testnet".*"mainnet" is being generated/);
    // fatal, so ALLOW_PARTIAL_REGISTRY_CHAIN=1 cannot wave it through, and the state is empty so
    // even a caller that ignored the flag cannot compare against the wrong environment.
    assert.equal(result.fatal, true);
    assert.deepEqual(result.accumulated, {});
    assert.deepEqual(result.layers, []);
});

test("collectRegistryChain refuses a mid-chain layer from the wrong network", async () => {
    const foreign = layer({ version: "v1", network: "testnet", chains: { 1: chain({ hub: "0xforeign" }) } });
    const { fetchImpl } = fakeFetch({ cidBase: foreign });
    const tip = layer({ version: "v2", chains: { 1: chain({ vault: "0xvault" }) } , previousCid: "cidBase" });

    const result = await collectRegistryChain(tip, {
        expectedNetwork: "mainnet",
        fetchOptions: { fetchImpl, ...noCache },
    });

    assert.equal(result.complete, false);
    assert.match(result.reason, /declares network "testnet"/);
    assert.equal(result.fatal, true);
    // The foreign layer must not reach the accumulated state even though the walk already had it.
    assert.deepEqual(result.accumulated, {});
});

test("collectRegistryChain accepts a layer that declares no network", async () => {
    // Every published layer carries `network` today, but treating an absent one as a mismatch
    // would turn a missing label on an old base snapshot into a hard generation failure.
    const base = layer({ version: "v1", network: null, chains: { 1: chain({ hub: "0xhub" }) } });
    const { fetchImpl } = fakeFetch({ cidBase: base });
    const tip = layer({ version: "v2", chains: {}, previousCid: "cidBase" });

    const result = await collectRegistryChain(tip, {
        expectedNetwork: "mainnet",
        fetchOptions: { fetchImpl, ...noCache },
    });

    assert.equal(result.complete, true);
    assert.equal(result.reason, null);
    assert.equal(result.accumulated["1"].contracts.hub.address, "0xhub");
});

test("collectRegistryChain refuses a tip that is not a registry document", async () => {
    // The tip arrives from the caller (the live HTTP endpoint), not from fetchRegistryFromIpfs,
    // so it needs its own check. Accepting it would flatten to an empty accumulated state and
    // make every published contract look new.
    const result = await collectRegistryChain({ detail: "cloudflare error page" }, {
        fetchOptions: noCache,
    });

    assert.equal(result.complete, false);
    assert.match(result.reason, /tip document is not a registry/);
    // Fatal for the same reason a network mismatch is: not incomplete but invalid, so no
    // "proceed anyway" override may apply.
    assert.equal(result.fatal, true);
    assert.deepEqual(result.layers, []);
    assert.deepEqual(result.accumulated, {});
});

test("collectRegistryChain returns ABI coverage alongside the accumulated state", async () => {
    // Callers need coverage from the same call that gives them contracts: comparing the two is how
    // an ABI the chain never carried is detected (see registry-delta.js).
    const base = { network: "mainnet", version: "v1", chains: { 1: chain({ hub: "0xhub" }) }, abis: { Hub: [] }, previousRegistry: null };
    const { fetchImpl } = fakeFetch({ cidBase: base });
    const tip = { network: "mainnet", version: "v2", chains: { 1: chain({ spoke: "0xspoke" }) }, abis: { Spoke: [] }, previousRegistry: { version: "v1", ipfsHash: "cidBase" } };

    const result = await collectRegistryChain(tip, { fetchOptions: { fetchImpl, ...noCache } });

    assert.deepEqual([...result.accumulatedAbis].sort(), ["Hub", "Spoke"]);
});

test("collectRegistryChain returns empty ABI coverage when the chain is rejected", async () => {
    const tip = layer({ version: "v2", network: "testnet", chains: { 1: chain({ hub: "0xhub" }) } });

    const result = await collectRegistryChain(tip, {
        expectedNetwork: "mainnet",
        fetchOptions: noCache,
    });

    assert.equal(result.fatal, true);
    assert.deepEqual([...result.accumulatedAbis], []);
});

test("flattenRegistryAbis collects every ABI name published across the chain", () => {
    const layers = [
        { chains: {}, abis: { Root: [], Gateway: [] } },
        { chains: {}, abis: { Gateway: [], Spoke: [] } },
    ];

    const names = flattenRegistryAbis(layers);

    assert.deepEqual([...names].sort(), ["Gateway", "Root", "Spoke"]);
    // A layer that ships no ABIs must not erase coverage from earlier layers.
    assert.deepEqual([...flattenRegistryAbis([...layers, { chains: {} }])].sort(), ["Gateway", "Root", "Spoke"]);
});
