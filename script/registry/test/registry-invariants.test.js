import { test } from "node:test";
import assert from "node:assert/strict";

import { checkDeltaInvariants } from "../utils/registry-invariants.js";
import { flattenRegistryChain } from "../utils/registry-chain.js";
import { chain, contract, layer } from "./helpers.js";

const address = (n) => `0x${String(n).repeat(40).slice(0, 40)}`;

test("a correct delta produces no findings", () => {
    const accumulatedChains = { 1: chain({ hub: contract(address(1), 100) }) };
    const deltaRegistry = { chains: { 1: chain({ spoke: contract(address(2), 200) }) } };
    const envChains = { 1: chain({ hub: contract(address(1), 100), spoke: contract(address(2), 200) }) };

    const { errors, warnings } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.deepEqual(errors, []);
    assert.deepEqual(warnings, []);
});

test("a delta that re-states published contracts is an error (original bug)", () => {
    // The 443-contract publish in miniature: the delta carries contracts identical to what the
    // published chain already holds. Every structural check passes; this one must not.
    const accumulatedChains = flattenRegistryChain([
        layer({ version: "v1", chains: { 1: chain({ hub: contract(address(1), 100), spoke: contract(address(2), 100) }) } }),
        layer({ version: "v2", chains: { 1: chain({ vault: contract(address(3), 200) }) } }),
    ]);
    const deltaRegistry = {
        chains: {
            1: chain({
                hub: contract(address(1), 100), // already published, unchanged
                spoke: contract(address(2), 100), // already published, unchanged
                vault: contract(address(3), 200), // already published, unchanged
            }),
        },
    };
    const envChains = {
        1: chain({ hub: contract(address(1), 100), spoke: contract(address(2), 100), vault: contract(address(3), 200) }),
    };

    const { errors, stats } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.equal(stats.redundantContracts, 3);
    assert.equal(errors.length, 3);
    for (const error of errors) assert.match(error.message, /Restates the published state/);
});

test("a contract in env but absent from the projected state is an error", () => {
    const accumulatedChains = { 1: chain({ hub: contract(address(1)) }) };
    const deltaRegistry = { chains: {} };
    const envChains = { 1: chain({ hub: contract(address(1)), spoke: contract(address(2)) }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.equal(errors.length, 1);
    assert.match(errors[0].message, /missing from the published state/);
    assert.equal(errors[0].path, "chains.1.contracts.spoke");
});

test("an address mismatch between the projected state and env is an error", () => {
    const accumulatedChains = { 1: chain({ hub: contract(address(1), 100) }) };
    // Delta claims a redeploy to address(9) while env says address(2) — a hand-edited or stale delta.
    const deltaRegistry = { chains: { 1: chain({ hub: contract(address(9), 200) }) } };
    const envChains = { 1: chain({ hub: contract(address(2), 200) }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.equal(errors.length, 1);
    assert.match(errors[0].message, /resolves to .* but env says/);
});

test("a blockNumber mismatch between the projected state and env is an error", () => {
    // The address alone is not the whole entry: the indexer starts this contract's listener at its
    // blockNumber, so a delta that leaves the wrong one published is not a projection of env.
    const accumulatedChains = { 1: chain({ hub: contract(address(1), 100) }) };
    const deltaRegistry = { chains: { 1: chain({ hub: contract(address(1), 999) }) } };
    const envChains = { 1: chain({ hub: contract(address(1), 200) }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.equal(errors.length, 1);
    assert.equal(errors[0].path, "chains.1.contracts.hub.blockNumber");
    assert.match(errors[0].message, /resolves to blockNumber 999 but env says 200/);
});

test("a delta backfilling a blockNumber the chain lacked is neither redundant nor a mismatch", () => {
    // Mirrors hasContractChanged: env gaining a blockNumber at an unchanged address is a real
    // change, so the entry must be allowed to carry it without tripping minimality.
    const accumulatedChains = { 1: chain({ hub: { address: address(1), blockNumber: null, txHash: null } }) };
    const deltaRegistry = { chains: { 1: chain({ hub: contract(address(1), 100) }) } };
    const envChains = { 1: chain({ hub: contract(address(1), 100) }) };

    const { errors, stats } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.deepEqual(errors, []);
    assert.equal(stats.redundantContracts, 0);
});

test("a projected blockNumber is not required when env states none", () => {
    const accumulatedChains = { 1: chain({ hub: contract(address(1), 100) }) };
    const deltaRegistry = { chains: {} };
    const envChains = { 1: chain({ hub: { address: address(1), blockNumber: null, txHash: null } }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.deepEqual(errors, []);
});

test("address comparison is case-insensitive", () => {
    const accumulatedChains = { 1: chain({ hub: contract("0xAbC0000000000000000000000000000000000001", 100) }) };
    const deltaRegistry = { chains: {} };
    const envChains = { 1: chain({ hub: contract("0xabc0000000000000000000000000000000000001", 100) }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.deepEqual(errors, []);
});

test("a contract dropped from env without a tombstone is an error", () => {
    const accumulatedChains = { 1: chain({ hub: contract(address(1)), guardian: contract(address(2)) }) };
    const deltaRegistry = { chains: {} };
    const envChains = { 1: chain({ hub: contract(address(1)) }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.equal(errors.length, 1);
    assert.match(errors[0].message, /should have been tombstoned/);
});

test("a tombstone for a contract dropped from env satisfies the projection", () => {
    const accumulatedChains = { 1: chain({ hub: contract(address(1)), guardian: contract(address(2)) }) };
    const deltaRegistry = { chains: { 1: chain({ guardian: contract(null) }) } };
    const envChains = { 1: chain({ hub: contract(address(1)) }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.deepEqual(errors, []);
});

test("re-tombstoning an already-retired contract is an error", () => {
    const accumulatedChains = { 1: chain({ hub: contract(address(1)), guardian: contract(null) }) };
    const deltaRegistry = { chains: { 1: chain({ guardian: contract(null) }) } };
    const envChains = { 1: chain({ hub: contract(address(1)) }) };

    const { errors, stats } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.equal(stats.redundantContracts, 1);
    assert.match(errors[0].message, /already retired/);
});

test("an oversized delta warns without erroring", () => {
    // 30 published contracts; the delta legitimately changes 25 of them (a broad redeploy), so it
    // must warn about the size but flag nothing as an error.
    const published = {};
    const env = {};
    const delta = {};
    for (let i = 0; i < 30; i++) {
        published[`c${i}`] = contract(address(i % 9), 100);
        if (i < 25) {
            env[`c${i}`] = contract(address((i % 9) + 1), 200);
            delta[`c${i}`] = contract(address((i % 9) + 1), 200);
        } else {
            env[`c${i}`] = contract(address(i % 9), 100);
        }
    }

    const { errors, warnings, stats } = checkDeltaInvariants({
        accumulatedChains: { 1: chain(published) },
        deltaRegistry: { chains: { 1: chain(delta) } },
        envChains: { 1: chain(env) },
    });

    assert.deepEqual(errors, []);
    assert.equal(stats.deltaContracts, 25);
    assert.equal(stats.accumulatedContracts, 30);
    assert.equal(warnings.length, 1);
    assert.match(warnings[0].message, /large for a delta/);
});

test("a small delta does not trip the size heuristic", () => {
    const published = {};
    const env = {};
    for (let i = 0; i < 30; i++) {
        published[`c${i}`] = contract(address(i % 9), 100);
        env[`c${i}`] = contract(address(i % 9), 100);
    }
    env.newOne = contract(address(7), 300);

    const { errors, warnings } = checkDeltaInvariants({
        accumulatedChains: { 1: chain(published) },
        deltaRegistry: { chains: { 1: chain({ newOne: contract(address(7), 300) }) } },
        envChains: { 1: chain(env) },
    });

    assert.deepEqual(errors, []);
    assert.deepEqual(warnings, []);
});

test("a delta chain with no env file warns rather than erroring", () => {
    const { errors, warnings } = checkDeltaInvariants({
        accumulatedChains: {},
        deltaRegistry: { chains: { 424242: chain({ hub: contract(address(1)) }) } },
        envChains: {},
    });

    assert.deepEqual(errors, []);
    assert.match(warnings[0].message, /no env file/);
});

test("a live contract whose ABI is nowhere in the chain is an error", () => {
    const accumulatedChains = { 1: chain({ tokenBridge: contract(address(1), 100) }) };
    const deltaRegistry = { chains: {}, abis: {} };
    const envChains = { 1: chain({ tokenBridge: contract(address(1), 100) }) };

    const { errors } = checkDeltaInvariants({
        accumulatedChains,
        accumulatedAbiNames: new Set(["Root"]),
        deltaRegistry,
        envChains,
    });

    assert.equal(errors.length, 1);
    assert.equal(errors[0].path, "abis.TokenBridge");
    assert.match(errors[0].message, /No layer in the chain carries this ABI/);
});

test("a restated contract is allowed when it ships an ABI the chain lacked", () => {
    // Minimality says "never restate published state"; healing an ABI gap is the one exception,
    // so the two rules must not fight. It warns rather than errors, to stay visible.
    const accumulatedChains = { 1: chain({ tokenBridge: contract(address(1), 100) }) };
    const deltaRegistry = {
        chains: { 1: chain({ tokenBridge: contract(address(1), 100) }) },
        abis: { TokenBridge: [] },
    };
    const envChains = { 1: chain({ tokenBridge: contract(address(1), 100) }) };

    const { errors, warnings } = checkDeltaInvariants({
        accumulatedChains,
        accumulatedAbiNames: new Set(["Root"]),
        deltaRegistry,
        envChains,
    });

    assert.deepEqual(errors, []);
    assert.equal(warnings.length, 1);
    assert.match(warnings[0].message, /ships TokenBridge/);
});

test("a retired contract needs no ABI coverage", () => {
    const accumulatedChains = { 1: chain({ guardian: contract(null) }) };
    const deltaRegistry = { chains: {}, abis: {} };
    const envChains = { 1: chain({}) };

    const { errors } = checkDeltaInvariants({
        accumulatedChains,
        accumulatedAbiNames: new Set(),
        deltaRegistry,
        envChains,
    });

    assert.deepEqual(errors, []);
});

test("ABI coverage is not checked when no accumulated coverage is supplied", () => {
    const accumulatedChains = { 1: chain({ tokenBridge: contract(address(1), 100) }) };
    const deltaRegistry = { chains: {}, abis: {} };
    const envChains = { 1: chain({ tokenBridge: contract(address(1), 100) }) };

    const { errors } = checkDeltaInvariants({ accumulatedChains, deltaRegistry, envChains });

    assert.deepEqual(errors, []);
});
